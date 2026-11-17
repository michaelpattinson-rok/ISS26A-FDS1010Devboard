/* Classic 16 MHz ATmega328P Uno R3 / Nano only. Board power is 3.3 V,
   even though this host's ADC reference and MCU run near 5 V.
   No digital output drives the detector board or charge fixture. */
#include <Arduino.h>
#include "avr_detector.h"
#if !defined(__AVR_ATmega328P__) || F_CPU != 16000000UL
#error "Select classic 16 MHz ATmega328P Uno or Nano; other families need their own firmware"
#endif
#if !defined(ARDUINO_AVR_UNO) && !defined(ARDUINO_AVR_NANO)
#error "Select Arduino Uno or classic Arduino Nano in the existing AVR core"
#endif
#ifndef FDS_AVR_AVCC_MV
#define FDS_AVR_AVCC_MV 5000UL /* Replace with measured host AVcc for mV estimates. */
#endif
#ifndef FDS_BOARD_3V3_MV
#define FDS_BOARD_3V3_MV 3300UL /* Replace with measured board 3V3. */
#endif
static uint16_t samples[fds_avr::N];
static fds_avr::Result result;
static float frozen_threshold;
static bool have_record,high_gain;
static uint32_t record_id,acquisition_us,gap_us,last_stop_us;
static char tag='b';
static_assert(sizeof(samples)+sizeof(result)+64<800,"Keep application capture state small on 2KB AVR SRAM");
static_assert(FDS_AVR_AVCC_MV>FDS_BOARD_3V3_MV,"ADC reference must exceed the analog rail; use DEFAULT AVcc");
static const uint16_t clip_low=(50UL*1024UL)/FDS_AVR_AVCC_MV;
static const uint16_t clip_high=((FDS_BOARD_3V3_MV-50UL)*1024UL)/FDS_AVR_AVCC_MV;
static bool conversion(uint16_t &v) {
    const uint32_t began=micros();uint16_t polls=0;
    while(!(ADCSRA&_BV(ADIF))) {
        /* Bounded even if the timer stops advancing. Normal ADC period is104us.
           Timer/serial interrupts remain enabled; timeout is not a jitter test. */
        if((uint32_t)(micros()-began)>=1000UL || ++polls>=16000u)return false;
    }
    v=ADC;
    ADCSRA|=_BV(ADIF); /* Clear completion flag; next free-run conversion continues. */
    return true;
}
static void acquisition_failed(uint32_t start) {
    ADCSRA=0;last_stop_us=micros();acquisition_us=last_stop_us-start;
    result=fds_avr::Result{};result.flags=fds_avr::TIMEOUT;
    have_record=false;record_id++;
}
static void acquire() {
    Serial.flush(); /* All previous USB-serial output is finished before capture. */
    delay(1000);     /* Reference settling is blind time, not counted exposure. */
    pinMode(A0,INPUT);digitalWrite(A0,LOW); /* No pullup, never an output. */
    analogReference(DEFAULT);             /* AVcc; leave AREF unwired. */
    ADCSRA=0;ADMUX=_BV(REFS0);            /* ADC0/A0, right aligned, AVcc reference. */
    ADCSRB=0;DIDR0|=_BV(ADC0D);
    ADCSRA=_BV(ADEN)|_BV(ADATE)|_BV(ADPS2)|_BV(ADPS1)|_BV(ADPS0)|_BV(ADIF);
    ADCSRA|=_BV(ADSC);
    uint32_t start=micros();gap_us=start-last_stop_us;
    uint16_t discarded;
    for(uint8_t i=0;i<16;i++)if(!conversion(discarded)){acquisition_failed(start);return;}
    start=micros();gap_us=start-last_stop_us;
    for(uint16_t i=0;i<fds_avr::N;i++)if(!conversion(samples[i])){acquisition_failed(start);return;}
    last_stop_us=micros();acquisition_us=last_stop_us-start;ADCSRA=0;
    have_record=true;record_id++;
    result=fds_avr::analyze(samples,frozen_threshold,clip_low,clip_high);
    /* 16MHz/128/13 ~9615.38 samples/s. Polling/interrupt delays are unqualified;
       this gross timing guard cannot prove that no individual conversion was missed. */
    const uint32_t expected=(uint32_t)fds_avr::N*104UL;
    if(acquisition_us<expected*9/10 || acquisition_us>expected*11/10) {
        result.flags|=fds_avr::TIMING;result.accepted=0;
    }
}
static void summary() {
    Serial.print(F("id="));Serial.print(record_id);Serial.print(F(" tag="));Serial.print(tag);
    Serial.print(F(" gain="));Serial.print(high_gain?F("HIGH53.3"):F("LOW27.15"));
    Serial.print(F(" baseline_codes="));Serial.print(result.baseline,2);
    Serial.print(F(" sigma_codes="));Serial.print(result.sigma,2);
    Serial.print(F(" threshold_codes="));Serial.print(result.threshold,2);
    Serial.print(F(" diagnostic_global_positive_codes="));Serial.print(result.positive,2);
    Serial.print(F(" diagnostic_global_negative_codes="));Serial.print(result.negative,2);
    Serial.print(F(" local_baseline_codes="));Serial.print(result.local_baseline,3);
    Serial.print(F(" local_sigma_codes="));Serial.print(result.local_sigma,3);
    Serial.print(F(" local_shift_codes="));Serial.print(result.local_shift,3);
    Serial.print(F(" local_slope_codes="));Serial.print(result.local_slope,3);
    Serial.print(F(" baseline_tolerance_codes="));Serial.print(result.baseline_tolerance,3);
    Serial.print(F(" diagnostic_local_peak_codes="));Serial.print(result.local_peak,3);
    Serial.print(F(" peak_status="));Serial.print(result.accepted?F("isolated_demo_only"):F("unqualified"));
    Serial.print(F(" trigger_sample="));Serial.print(result.start);
    Serial.print(F(" peak_sample="));Serial.print(result.peak);
    Serial.print(F(" positive_end_sample="));Serial.print(result.end);
    Serial.print(F(" candidates="));Serial.print(result.candidates);
    Serial.print(F(" accepted="));Serial.print(result.accepted);
    Serial.print(F(" flags="));Serial.print(result.flags);
    Serial.print(F(" raw_us="));Serial.print(acquisition_us);
    Serial.print(F(" nominal_trigger_window_samples="));Serial.print(result.observation);
    Serial.print(F(" blocked_trigger_samples="));Serial.print(result.dead);
    Serial.print(F(" rate_exposure_us=unqualified"));
    Serial.print(F(" blind_gap_us="));Serial.println(gap_us);
}
static void help() {
    Serial.println(F("Rev E classic Uno/Nano: 3V3 ONLY to board; GND; ADC_OUT to A0. Leave AREF unwired."));
    Serial.println(F("c=quiet calibration b=background s=source d=raw dump l/h=physical gain label ?=help"));
    Serial.println(F("No GPIO fixture output. Change physical gain with power off. ADC 10bit, nominal 9615sps."));
    Serial.println(F("One isolated pulse: threshold crossing samples64..127 only; positive lobe must end before240."));
    Serial.println(F("Local baseline gate is empirical. Diagnostic peaks are uncalibrated; no rate/energy/dose claim."));
}
void setup() {
    Serial.begin(115200);pinMode(A0,INPUT);digitalWrite(A0,LOW);analogReference(DEFAULT);
    last_stop_us=micros();help();
}
void loop() {
    if(!Serial.available())return;
    char command=(char)Serial.read();
    if(command=='?'){help();return;}
    if(command=='l'||command=='h'){high_gain=command=='h';frozen_threshold=0;Serial.println(F("Gain metadata changed; c required."));return;}
    if(command=='d') {
        if(!have_record){Serial.println(F("No record"));return;}
        Serial.println(F("sample,nominal_us,adc_code,approx_mv"));
        for(uint16_t i=0;i<fds_avr::N;i++) {
            Serial.print(i);Serial.print(',');Serial.print((uint32_t)i*104UL);Serial.print(',');
            Serial.print(samples[i]);Serial.print(',');Serial.println((uint32_t)samples[i]*FDS_AVR_AVCC_MV/1024UL);
        }
        return;
    }
    if(command!='c'&&command!='b'&&command!='s')return;
    if(command!='c'&&frozen_threshold<=0){Serial.println(F("Run quiet dark c calibration first"));return;}
    float previous_threshold=frozen_threshold;
    if(command=='c')frozen_threshold=0;
    tag=command;acquire();
    if(command=='c') {
        bool clean=!result.flags && result.candidates==0 && result.positive<=result.threshold && -result.negative<=result.threshold;
        if(clean){frozen_threshold=result.threshold;Serial.println(F("Quiet threshold frozen"));}
        else {frozen_threshold=previous_threshold;Serial.println(F("Calibration rejected; prior threshold retained. Inspect raw data/noise/clipping."));}
    }
    summary();
}
