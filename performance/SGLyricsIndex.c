#include "SGLyricsIndex.h"
#include <math.h>
#include <stdlib.h>

struct SGTimeIndex {
    const SGTimeSpan *spans;
    size_t count, leaves;
    double *maxEnd;
};

SGTimeIndex *SGTimeIndexCreate(const SGTimeSpan *spans, size_t count) {
    // Bound auxiliary memory. Unusually large or unordered providers use the core.
    if (!spans || !count || count > 16384) return NULL;
    for (size_t i = 1; i < count; i++)
        if ((double)spans[i].start < (double)spans[i - 1].start) return NULL;
    SGTimeIndex *index = calloc(1, sizeof(*index));
    if (!index) return NULL;
    size_t leaves = 1;
    while (leaves < count) leaves *= 2;
    index->maxEnd = malloc(2 * leaves * sizeof(double));
    if (!index->maxEnd) { free(index); return NULL; }
    index->spans = spans;
    index->count = count;
    index->leaves = leaves;
    for (size_t i = 0; i < leaves; i++)
        index->maxEnd[leaves + i] = i < count ? (double)spans[i].end : -INFINITY;
    for (size_t i = leaves - 1; i > 0; i--)
        index->maxEnd[i] = fmax(index->maxEnd[i * 2], index->maxEnd[i * 2 + 1]);
    return index;
}

void SGTimeIndexDestroy(SGTimeIndex *index) {
    if (!index) return;
    free(index->maxEnd);
    free(index);
}

static size_t firstLive(const SGTimeIndex *index, size_t node, size_t left, size_t right,
                        size_t from, size_t limit, double time) {
    if (right <= from || left >= limit || index->maxEnd[node] <= time) return SIZE_MAX;
    if (right - left == 1) return left;
    size_t middle = left + (right - left) / 2;
    size_t result = firstLive(index, node * 2, left, middle, from, limit, time);
    return result != SIZE_MAX ? result : firstLive(index, node * 2 + 1, middle, right, from, limit, time);
}

bool SGTimeIndexQuery(const SGTimeIndex *index, double time, const SGTimeBreak *breaks,
                      size_t breakCount, int64_t active[6], size_t *activeCount,
                      int64_t *focus, int64_t *openBreak) {
    if (!index || !isfinite(time) || (breakCount && !breaks) || !active ||
        !activeCount || !focus || !openBreak) return false;
    size_t low = 0, high = index->count;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if ((double)index->spans[mid].start <= time) low = mid + 1;
        else high = mid;
    }
    size_t started = low;
    int64_t latest = (int64_t)started - 1, breakLine = -1;
    *openBreak = -1;
    // Preserve the original order/precedence for overlaps and its exact boundaries.
    for (size_t i = 0; i < breakCount; i++) {
        if (time >= (double)breaks[i].start && time < (double)breaks[i].end) {
            breakLine = breaks[i].line;
            if (time < (double)breaks[i].end - 500.0) *openBreak = breakLine;
        }
    }
    size_t count = 0, from = 0;
    while (count < 6 && from < started) {
        size_t row = firstLive(index, 1, 0, index->leaves, from, started, time);
        if (row == SIZE_MAX) break;
        active[count++] = (int64_t)row;
        from = row + 1;
    }
    // The core keeps the latest line selected after its end when outside a break.
    if (count < 6 && latest >= 0 && breakLine < 0 &&
        (double)index->spans[latest].end <= time) active[count++] = latest;
    *activeCount = count;
    *focus = breakLine >= 0 ? breakLine : (count ? active[0] : latest);
    return true;
}
