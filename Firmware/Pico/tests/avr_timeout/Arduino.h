#ifndef TEST_ARDUINO_H
#define TEST_ARDUINO_H
#include <stdint.h>
#define _BV(x) (1U<<(x))
#define F(x) x
#define INPUT 0
#define LOW 0
#define A0 14
#define DEFAULT 1
#define ADIF 4
#define REFS0 6
#define ADC0D 0
#define ADEN 7
#define ADATE 5
#define ADPS2 2
#define ADPS1 1
#define ADPS0 0
#define ADSC 6
struct ADCStatus {
    uint8_t value;int ready;unsigned reads;
    operator uint8_t(){++reads;bool done=(value&_BV(ADEN)) && ready!=0;if(done&&ready>0)--ready;return uint8_t(value|(done?_BV(ADIF):0));}
    ADCStatus& operator=(uint8_t v){value=v&~_BV(ADIF);return *this;}
    ADCStatus& operator|=(uint8_t v){value|=v&~_BV(ADIF);return *this;}
};
extern ADCStatus ADCSRA;
extern uint8_t ADMUX,ADCSRB,DIDR0;
extern uint16_t ADC;
void delay(unsigned long);unsigned long micros();void pinMode(int,int);void digitalWrite(int,int);void analogReference(int);
struct SerialStub {void begin(long){}void flush(){}int available(){return 0;}int read(){return -1;}template<class T>void print(T){}template<class T>void print(T,int){}template<class T>void println(T){} };
extern SerialStub Serial;
#endif
