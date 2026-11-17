#pragma once

// Larger software transfers for native USB CDC. Full speed USB still uses
// the endpoint packet size set by the Arduino board descriptors.
#include "tusb_config.h"
#undef CFG_TUD_CDC_TX_BUFSIZE
#define CFG_TUD_CDC_TX_BUFSIZE 1536
