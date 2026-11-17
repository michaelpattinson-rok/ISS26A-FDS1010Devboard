// Native API/register simulation exercises the actual sketch timeout paths.
// This does not compile/link an AVR core or validate real ADIF semantics/timing.
#include <cassert>
#include <cstdio>
#include "Arduino.h"
ADCStatus ADCSRA={0,0,0};uint8_t ADMUX,ADCSRB,DIDR0;uint16_t ADC=338;
SerialStub Serial;static unsigned long ticks;static bool timer_stalled;
void delay(unsigned long){}unsigned long micros(){if(!timer_stalled)++ticks;return ticks;}
void pinMode(int,int){}void digitalWrite(int,int){}void analogReference(int){}
#include "../../Arduino/RevE_Arduino/RevE_Arduino.ino"
int main(){
    uint16_t value=999;
    ADCSRA=uint8_t(_BV(ADEN));ADCSRA.ready=0;ADCSRA.reads=0;ticks=0;timer_stalled=false;
    assert(!conversion(value));assert(value==999);assert(ticks<=1002);assert(ADCSRA.reads<=1001);
    ADCSRA=uint8_t(_BV(ADEN));ADCSRA.ready=0;ADCSRA.reads=0;timer_stalled=true;
    assert(!conversion(value));assert(ADCSRA.reads==16000);assert(value==999);
    timer_stalled=false;ticks=0;ADCSRA.ready=0;ADCSRA.reads=0;have_record=true;
    result.accepted=1;acquire();
    assert(result.flags==fds_avr::TIMEOUT);assert(!result.accepted);assert(!have_record);assert(ADCSRA.value==0);
    ADCSRA.ready=21;ADCSRA.reads=0;have_record=true;result.accepted=1;acquire();
    assert(result.flags==fds_avr::TIMEOUT);assert(!result.accepted);assert(!have_record);assert(ADCSRA.value==0);
    std::puts("PASS: 15 timeout-path assertions: conversion1ms deadline; stalled-timer16000-poll bound; warmup abort; partial-capture abort; ADC stopped; no accepted/stale raw record. Native stub only, not AVR timing/core/hardware qualification.");
}
