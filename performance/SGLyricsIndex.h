#ifndef SG_LYRICS_INDEX_H
#define SG_LYRICS_INDEX_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct { int64_t start, end; } SGTimeSpan;
typedef struct { int64_t start, end, line; } SGTimeBreak;
typedef struct SGTimeIndex SGTimeIndex;
// The caller owns immutable spans until destroy; timeLines invalidates this index.
SGTimeIndex *SGTimeIndexCreate(const SGTimeSpan *spans, size_t count);
void SGTimeIndexDestroy(SGTimeIndex *index);
// Matches the pinned 0.51.0 sungAt: contract: at most six earliest active lines,
// current/break focus and the break's final 500 ms exclusion. No query allocation.
bool SGTimeIndexQuery(const SGTimeIndex *index, double time, const SGTimeBreak *breaks,
                      size_t breakCount, int64_t active[6], size_t *activeCount,
                      int64_t *focus, int64_t *openBreak);
#endif
