#include <Arduino.h>
#include <FspTimer.h>
#include <IRQManager.h>
#include <r_adc.h>
#include <r_dtc.h>
#include <r_elc.h>
#include "tusb.h"
#include <inttypes.h>

namespace {
constexpr uint32_t clockHz = 48000000;
constexpr uint16_t blockSamples = 1024;
constexpr uint8_t queueSlots = 6;
constexpr uint8_t headerBytes = 64;
constexpr uint32_t leaseMillis = 3000;
constexpr uint64_t maxRunSamples = 3605000000ULL;
constexpr uint8_t analogChannels[] = {9, 0, 1};
constexpr uint16_t analogPins[] = {A0, A1, A2};

struct Block {
    uint16_t words[blockSamples];
    uint64_t endUS;
};
Block blocks[queueSlots];
uint8_t tx[headerBytes + 2 * blockSamples];
size_t txSize, txOffset;
uint32_t crcTable[256];

FspTimer timer;
adc_instance_ctrl_t adc{};
adc_cfg_t adcConfig{};
adc_extended_cfg_t adcExtra{};
adc_channel_cfg_t adcChannel{};
dtc_instance_ctrl_t dtc{};
dtc_extended_cfg_t dtcExtra{};
transfer_info_t transfer{};
GenericIrqCfg_t interrupt{};
elc_instance_ctrl_t elc{};
elc_cfg_t elcConfig{};
R_GPT0_Type *sampleTimer;

volatile uint32_t produced, consumed, peak;
volatile bool armed, ended, stopRequested;
volatile uint32_t stopReason;
volatile uint64_t startUS;
uint32_t leaseAt;
uint64_t stream, boot, sentCount, stampHigh;
uint64_t txWaitAt, totalWaitUS, maximumWaitUS;
uint32_t maximumPackUS;
uint32_t previousStamp, sequence, period, directions, levels;
bool initialized, active, manual, outputLease, gpioPending, endQueued, packed;
char command[128];
uint8_t control[24];
size_t cmdLen, cmdControl;
bool commandOverflow;

uint32_t crc(const uint8_t *data, size_t bytes, uint32_t state = 0xffffffffu) {
    while (bytes--) state = crcTable[(state ^ *data++) & 255u] ^ (state >> 8);
    return state;
}
void put(uint8_t *to, uint64_t value, uint8_t count) {
    while (count--) { *to++ = value; value >>= 8; }
}
uint64_t get(const uint8_t *from, uint8_t count) {
    uint64_t value = 0;
    while (count) value = (value << 8) | from[--count];
    return value;
}
uint64_t timeUS() {
    const uint32_t state = __get_PRIMASK();
    __disable_irq();
    uint32_t ticks = DWT->CYCCNT;
    if (ticks < previousStamp) stampHigh += (1ULL << 32);
    previousStamp = ticks;
    uint64_t time = stampHigh | ticks;
    __set_PRIMASK(state);
    return time / (clockHz / 1000000u) + 1;
}
void releasePins() {
    for (uint8_t pin = 2; pin <= 12; ++pin)
        if (directions & (1u << pin)) pinMode(pin, INPUT);
    directions = levels = 0;
    outputLease = false;
}
void frame(uint8_t kind, uint64_t index, uint64_t time, uint32_t count, uint32_t auxiliary, uint32_t flags, size_t bytes) {
    memcpy(tx, "SBS1", 4);
    tx[4] = 1;
    tx[5] = kind;
    put(tx + 6, headerBytes, 2);
    put(tx + 8, bytes, 4);
    put(tx + 12, sequence++, 4);
    put(tx + 16, stream, 8);
    put(tx + 24, boot, 8);
    put(tx + 32, index, 8);
    put(tx + 40, time, 8);
    put(tx + 48, count, 4);
    put(tx + 52, auxiliary, 4);
    put(tx + 56, flags, 4);
    put(tx + 60, crc(tx + headerBytes, bytes, crc(tx, 60)) ^ 0xffffffffu, 4);
    txSize = headerBytes + bytes;
    txOffset = 0;
}
void haltADC(uint32_t reason) {
    sampleTimer->GTCR_b.CST = 0;
    armed = false;
    stopReason = reason;
    ended = true;
}
void captureComplete() {
    R_BSP_IrqStatusClear(interrupt.irq);
    if (!armed) return;
    if (transfer.length != 0) {
        haltADC(2);
        return;
    }
    const uint32_t count = produced + 1;
    const uint32_t depth = count - consumed;

    // Stop if the timer or ADC reached another conversion before rearming.
    if (!stopRequested && depth < queueSlots && uint64_t(count) * blockSamples < maxRunSamples - blockSamples) {
        // This vector has reached transfer end. Rearm its descriptor without
        // the general driver reset, which is too slow between ADC triggers.
        R_ICU->IELSR_b[interrupt.irq].DTCE = 0;
        R_DTC->DTCCR = 0x08;
        transfer.p_dest = blocks[count % queueSlots].words;
        transfer.length = blockSamples;
        __DMB();
        R_DTC->DTCCR = 0x18;
        if (R_ICU->IELSR_b[interrupt.irq].IR) haltADC(2);
        else R_ICU->IELSR_b[interrupt.irq].DTCE = 1;
    } else {
        haltADC(stopRequested ? 0 : 1);
    }
    blocks[produced % queueSlots].endUS = timeUS();
    if (depth > peak) peak = depth;
    __DMB();
    produced = count;
}
bool initAcquisition() {
    uint8_t type = GPT_TIMER;
    int8_t channel = FspTimer::get_available_timer(type);
    if (type != GPT_TIMER || channel < 0 || channel > 7) return false;
    R_GPT0_Type *const timers[] = {R_GPT0, R_GPT1, R_GPT2, R_GPT3, R_GPT4, R_GPT5, R_GPT6, R_GPT7};
    sampleTimer = timers[channel];
    const elc_event_t events[] = {ELC_EVENT_GPT0_COUNTER_OVERFLOW, ELC_EVENT_GPT1_COUNTER_OVERFLOW,
                                 ELC_EVENT_GPT2_COUNTER_OVERFLOW, ELC_EVENT_GPT3_COUNTER_OVERFLOW,
                                 ELC_EVENT_GPT4_COUNTER_OVERFLOW, ELC_EVENT_GPT5_COUNTER_OVERFLOW,
                                 ELC_EVENT_GPT6_COUNTER_OVERFLOW, ELC_EVENT_GPT7_COUNTER_OVERFLOW};
    if (!timer.begin(TIMER_MODE_PERIODIC, GPT_TIMER, channel, 480u, 0u, TIMER_SOURCE_DIV_1) ||
        !timer.open()) return false;
    if (R_ELC_Open(&elc, &elcConfig) != FSP_SUCCESS ||
        R_ELC_LinkSet(&elc, ELC_PERIPHERAL_ADC0, events[channel]) != FSP_SUCCESS ||
        R_ELC_Enable(&elc) != FSP_SUCCESS) return false;

    interrupt.irq = FSP_INVALID_VECTOR;
    interrupt.ipl = 1;
    interrupt.event = ELC_EVENT_ADC0_SCAN_END;
    if (!IRQManager::getInstance().addGenericInterrupt(interrupt, captureComplete)) return false;
    dtcExtra.activation_source = interrupt.irq;
    transfer.transfer_settings_word_b.dest_addr_mode = TRANSFER_ADDR_MODE_INCREMENTED;
    transfer.transfer_settings_word_b.src_addr_mode = TRANSFER_ADDR_MODE_FIXED;
    transfer.transfer_settings_word_b.irq = TRANSFER_IRQ_END;
    transfer.transfer_settings_word_b.size = TRANSFER_SIZE_2_BYTE;
    transfer.transfer_settings_word_b.mode = TRANSFER_MODE_NORMAL;
    transfer.p_src = const_cast<const uint16_t *>(&R_ADC0->ADDR[9]);
    transfer.p_dest = blocks[0].words;
    transfer.length = blockSamples;
    const transfer_cfg_t transferConfig{&transfer, &dtcExtra};
    if (R_DTC_Open(&dtc, &transferConfig) != FSP_SUCCESS) return false;

    adcExtra.adc_vref_control = ADC_VREF_CONTROL_AVCC0_AVSS0;
    adcExtra.window_a_irq = adcExtra.window_b_irq = FSP_INVALID_VECTOR;
    adcExtra.window_a_ipl = adcExtra.window_b_ipl = BSP_IRQ_DISABLED;
    adcConfig.unit = 0;
    adcConfig.mode = ADC_MODE_SINGLE_SCAN;
    adcConfig.resolution = ADC_RESOLUTION_14_BIT;
    adcConfig.alignment = ADC_ALIGNMENT_RIGHT;
    adcConfig.trigger = ADC_TRIGGER_SYNC_ELC;
    adcConfig.scan_end_irq = adcConfig.scan_end_b_irq = FSP_INVALID_VECTOR;
    adcConfig.scan_end_ipl = adcConfig.scan_end_b_ipl = BSP_IRQ_DISABLED;
    adcConfig.p_extend = &adcExtra;
    return R_ADC_Open(&adc, &adcConfig) == FSP_SUCCESS;
}
bool start(uint8_t channel, uint32_t rate) {
    const uint8_t input = analogChannels[channel];
    if (R_IOPORT_PinCfg(&g_ioport_ctrl, digitalPinToBspPin(analogPins[channel]), IOPORT_CFG_ANALOG_ENABLE) != FSP_SUCCESS)
        return false;
    adcChannel.scan_mask = 1u << input;
    if (R_ADC_ScanCfg(&adc, &adcChannel) != FSP_SUCCESS) return false;
    R_ADC0->ADSSTR[input] = rate == 500000 ? 32 : 64;
    if (R_DTC_Reset(&dtc, const_cast<const uint16_t *>(&R_ADC0->ADDR[input]), blocks[0].words, blockSamples) != FSP_SUCCESS ||
        !timer.set_period(period) || !timer.reset() || R_ADC_ScanStart(&adc) != FSP_SUCCESS) return false;
    startUS = timeUS();
    armed = true;
    if (!timer.start()) {
        armed = false;
        (void)R_ADC_ScanStop(&adc);
        (void)R_DTC_Disable(&dtc);
        return false;
    }
    return true;
}
void queueText(const char *text) {
    const size_t length = strlen(text);
    if (!txSize && length < sizeof(tx)) {
        memcpy(tx, text, length);
        txSize = length;
        txOffset = 0;
    }
}
void parseStart() {
    uint64_t token = 0;
    char tokenHex[17]{};
    unsigned channel = 0, hz = 0;
    char mode[9]{}, packing[8]{};
    int length = 0;
    const int fields = sscanf(command, "SB1 STREAM %16[0123456789abcdefABCDEF] %1u %8s %6u %7s%n", tokenHex, &channel, mode, &hz, packing, &length);
    for (const char ch : tokenHex) {
        if (!ch) break;
        const char hex = ch | 0x20;
        token = (token << 4) | unsigned(hex <= '9' ? hex - '0' : hex - 'a' + 10);
    }
    if (!initialized || strlen(tokenHex) != 16 || fields != 5 || command[length] || !token || channel > 2 ||
        (hz != 100000 && hz != 250000 && hz != 500000) ||
        (strcmp(packing, "RAW14") && strcmp(packing, "PACK14")) ||
        (strcmp(mode, "RAW") && strcmp(mode, "DIAG") && strcmp(mode, "MANUAL")) ||
        (channel != 0 && strcmp(mode, "DIAG"))) {
        queueText("SB1 ERROR unsupported_start\n");
        return;
    }
    stream = token;
    period = clockHz / hz;
    packed = !strcmp(packing, "PACK14");
    manual = !strcmp(mode, "MANUAL");
    outputLease = manual;
    produced = consumed = peak = sequence = stopReason = sentCount = 0;
    endQueued = ended = gpioPending = stopRequested = false;
    txWaitAt = totalWaitUS = maximumWaitUS = maximumPackUS = 0;
    leaseAt = millis();
    if (!start(channel, hz)) { releasePins(); queueText("SB1 ERROR adc_start\n"); return; }
    active = true;
    put(tx + headerBytes, clockHz, 4);
    put(tx + headerBytes + 4, period, 4);
    frame(1, 0, startUS, 0, hz, channel, 8);
}
void controls() {
    if (control[4] != 1 || control[7] != 0 || get(control + 8, 8) != stream ||
        get(control + 16, 4) != 0 || get(control + 20, 4) != (crc(control, 20) ^ 0xffffffffu)) return;
    const uint8_t op = control[5], pin = control[6];
    if (op == 1 && pin == 0) {
        releasePins();
        stopRequested = true;
        gpioPending = manual;
    } else if (op == 6 && pin == 0) {
        releasePins();
        gpioPending = manual;
    } else if (!stopRequested && !ended && op == 2 && pin == 0) {
        leaseAt = millis();
        gpioPending = manual;
    } else if (!stopRequested && !ended && manual && outputLease && pin >= 2 && pin <= 12 && op >= 3 && op <= 5 &&
               uint32_t(millis() - leaseAt) < leaseMillis) {
        const uint32_t bit = 1u << pin;
        if (op == 3) {
            pinMode(pin, INPUT);
            directions &= ~bit;
            levels &= ~bit;
        } else {
            digitalWrite(pin, op == 5 ? HIGH : LOW);
            pinMode(pin, OUTPUT);
            directions |= bit;
            levels = op == 5 ? levels | bit : levels & ~bit;
        }
        gpioPending = true;
    }
}
void receiveUSB() {
    for (unsigned n = 0; n < 256 && tud_cdc_available(); ++n) {
        const int byte = tud_cdc_read_char();
        if (byte < 0) break;
        if (active) {
            const char *signature = "SBC1";
            if (cmdControl < 4 && byte != signature[cmdControl]) cmdControl = byte == 'S' ? 1 : 0;
            else {
                control[cmdControl++] = uint8_t(byte);
                if (cmdControl == sizeof(control)) { controls(); cmdControl = 0; }
            }
        } else if (!cmdLen && !commandOverflow && byte == '?') {
            if (!boot) {
                const auto *id = R_BSP_UniqueIdGet();
                boot = (uint64_t(id->unique_id_words[0] ^ id->unique_id_words[2]) << 32) |
                       (id->unique_id_words[1] ^ id->unique_id_words[3] ^ uint32_t(timeUS()));
                if (!boot) boot = 1;
            }
            char line[256];
            snprintf(line, sizeof(line), "SB1 HELLO version=1 target=uno_r4_minima fixture=0 firmware=1.0 stream=%u boot_id=%08lx%08lx"
                " rates=100000,250000,500000 diag_channels=0,1,2 adc=raw14 pack14=1\nSB1 STATUS pending=-\n",
                initialized ? 1u : 0u, static_cast<unsigned long>(boot >> 32), static_cast<unsigned long>(uint32_t(boot)));
            queueText(line);
        } else if (byte == '\n') {
            if (cmdLen && !commandOverflow && !txSize) { command[cmdLen] = 0; parseStart(); }
            cmdLen = 0;
            commandOverflow = false;
        } else if (byte != '\r' && !commandOverflow) {
            if (cmdLen < sizeof(command) - 1) command[cmdLen++] = char(byte);
            else commandOverflow = true;
        }
    }
}
void dispatch() {
    if (txSize) return;
    if (endQueued) { active = false; return; }
    if (gpioPending && !directions && (stopRequested || ended)) {
        memset(tx + headerBytes, 0, 16);
        frame(3, uint64_t(produced) * blockSamples, timeUS(), 0, 0, 0, 16);
        gpioPending = false;
        return;
    }
    if (consumed != produced) {
        __DMB();
        const auto &block = blocks[consumed % queueSlots];
        const uint64_t index = uint64_t(consumed) * blockSamples;
        const uint32_t count = blockSamples;
        uint8_t *dest = tx + headerBytes;
        const uint64_t packingStart = timeUS();
        bool canPack = packed;
        if (canPack) {
            for (unsigned i = 0; i < count; i += 4) {
                const uint16_t a=block.words[i], b=block.words[i+1], c=block.words[i+2], d=block.words[i+3];
                if ((a|b|c|d) & 0xc000) { canPack = false; break; }
                dest[0]=uint8_t(a); dest[1]=uint8_t((a>>8)|(b<<6)); dest[2]=uint8_t(b>>2);
                dest[3]=uint8_t((b>>10)|(c<<4)); dest[4]=uint8_t(c>>4);
                dest[5]=uint8_t((c>>12)|(d<<2)); dest[6]=uint8_t(d>>6);
                dest += 7;
            }
        }
        if (!canPack) memcpy(tx + headerBytes, block.words, count * sizeof(uint16_t));
        frame(2, index, block.endUS, count, 0, canPack ? 8 : 0, count * (canPack ? 7 : 8) / 4);
        maximumPackUS = max(maximumPackUS, uint32_t(timeUS() - packingStart));
        sentCount += count;
        __DMB();
        ++consumed;
    } else if (gpioPending) {
        uint32_t input = 0;
        for (uint8_t pin = 2; pin <= 12; ++pin)
            if (digitalRead(pin)) input |= 1u << pin;
        put(tx + headerBytes, directions, 4);
        put(tx + headerBytes + 4, input, 4);
        put(tx + headerBytes + 8, levels, 4);
        put(tx + headerBytes + 12, outputLease ? 1 : 0, 4);
        frame(3, uint64_t(produced) * blockSamples, timeUS(), 0, 0, 0, 16);
        gpioPending = false;
    } else if (ended) {
        (void)R_ADC_ScanStop(&adc);
        (void)R_DTC_Disable(&dtc);
        put(tx + headerBytes, sentCount, 8);
        put(tx + headerBytes + 8, peak, 4);
        put(tx + headerBytes + 12, maximumPackUS, 4);
        put(tx + headerBytes + 16, maximumWaitUS, 8);
        put(tx + headerBytes + 24, totalWaitUS, 8);
        frame(4, uint64_t(produced) * blockSamples, timeUS(), 0, stopReason, stopReason ? 1 : 0, 32);
        endQueued = true;
    }
}
} // namespace

void setup() {
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0;
    DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
    for (unsigned i = 0; i < 256; ++i) {
        uint32_t value = i;
        for (int bit = 0; bit < 8; ++bit)
            value = (value >> 1) ^ ((value & 1u) ? 0xedb88320u : 0);
        crcTable[i] = value;
    }
    for (uint8_t pin = 2; pin <= 12; ++pin) pinMode(pin, INPUT);
    initialized = initAcquisition();
    boot = 0;
}
void loop() {
    tud_task();
    (void)timeUS(); // Maintain the extended cycle clock even between runs.
    if (!tud_cdc_connected()) {
        releasePins();
        if (active) {
            const uint32_t state = __get_PRIMASK();
            __disable_irq();
            if (armed) haltADC(3);
            __set_PRIMASK(state);
            (void)R_ADC_ScanStop(&adc);
            (void)R_DTC_Disable(&dtc);
        }
        active = false;
        txSize = cmdLen = cmdControl = 0;
        commandOverflow = false;
        return;
    }
    receiveUSB();
    if (active && !ended && uint32_t(millis() - leaseAt) >= leaseMillis) {
        releasePins();
        const uint32_t state = __get_PRIMASK();
        __disable_irq();
        if (armed) haltADC(4);
        __set_PRIMASK(state);
        gpioPending = manual;
    }
    if (active && ended && outputLease) { releasePins(); gpioPending = manual; }
    if (active) dispatch();
    if (txSize) {
        if (!tud_cdc_write_available()) {
            if (!txWaitAt && active) txWaitAt = timeUS();
            return;
        }
        if (txWaitAt) {
            const uint64_t wait = timeUS() - txWaitAt;
            maximumWaitUS = max(maximumWaitUS, wait);
            totalWaitUS += wait;
            txWaitAt = 0;
        }
        const size_t written = tud_cdc_write(tx + txOffset, txSize - txOffset);
        txOffset += written;
        if (txOffset == txSize) txSize = txOffset = 0;
        if (written && !txSize && (!active || endQueued || consumed == produced)) tud_cdc_write_flush();
    }
}
