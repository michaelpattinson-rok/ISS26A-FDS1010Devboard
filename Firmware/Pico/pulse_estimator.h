#ifndef FDS1010_REVE_ESTIMATOR_H
#define FDS1010_REVE_ESTIMATOR_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define FDS_ALGORITHM_VERSION 2u
typedef enum { FDS_POLARITY_NEGATIVE=-1, FDS_POLARITY_POSITIVE=1 } fds_polarity;
#define FDS_BASELINE_SAMPLES 2048u
#define FDS_MAX_EVENTS 48u
enum fds_flags {
    FDS_BAD_ARGUMENT=1u, FDS_ADC_ERROR=2u, FDS_CLIPPING=4u,
    FDS_BAD_BASELINE=8u, FDS_NOISY_BASELINE=16u, FDS_BASELINE_CONTAMINATED=32u,
    FDS_BASELINE_DRIFT=64u, FDS_EVENT_OVERFLOW=128u,
    FDS_PILEUP=256u, FDS_SHORT_SPIKE=512u, FDS_LONG_PULSE=1024u,
    FDS_BOUNDARY_PULSE=2048u, FDS_THRESHOLD_BELOW_NOISE=4096u,
    FDS_LOCAL_BASELINE=8192u
};
typedef struct {
    uint32_t recovery_samples, minimum_above_threshold_samples;
    uint32_t max_positive_samples, end_guard_samples, local_baseline_samples;
    float trigger_sigma, minimum_threshold_codes, maximum_sigma_codes;
    float fixed_threshold_codes, maximum_local_offset_codes, maximum_local_slope_codes;
} fds_config;
typedef struct { uint16_t work[FDS_BASELINE_SAMPLES]; } fds_workspace;
typedef struct {
    uint32_t start, peak, end, flags, above_threshold_samples, contiguous_above_samples;
    float peak_delta_codes, negative_tail_codes;
    float local_baseline_codes, local_offset_codes, local_slope_codes;
    float baseline_tolerance_codes, slope_tolerance_codes, local_sigma_codes;
} fds_event;
typedef struct {
    uint32_t quality_flags, adc_errors, clipped_samples;
    uint32_t candidates, accepted, stored, analysis_start, analysis_end;
    uint32_t dead_samples, observation_samples;
    float baseline, baseline_rms, sigma, threshold, tail_baseline_shift;
    bool valid_record;
    fds_event events[FDS_MAX_EVENTS];
} fds_result;
fds_config fds_default_config(void);
void fds_analyze_profile(const uint16_t *, size_t, const fds_config *, fds_workspace *, fds_result *, fds_polarity);
uint32_t fds_algorithm_version(void);
void fds_analyze(const uint16_t *, size_t, const fds_config *, fds_workspace *, fds_result *);
#endif
