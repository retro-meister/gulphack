#include <stddef.h>
#include <stdint.h>

extern void SelectRender(int flags);
extern void PrimitiveBuffer_Insert(uint32_t *primitive);
extern void WorldToScreenVec3(int *out, int *worldIn, unsigned shift);
extern void DrawNumberSmall(int value, int screenPosX, int screenPosY, int colorIndex);

extern int     GAME_gameState;
extern uint8_t GAME_level_id;
extern uint8_t *primitiveBuffer_next;
extern uint8_t *primitiveBuffer_end;
extern uint8_t gulpBird0Data[];

#define GULP_FIGHT_LEVEL_ID         0x2e
#define GULP_RENDER_GAMEPLAY_FLAGS  0x3d

#define GULP_ARENA_FLOOR_Z          18944
#define DROP_TARGET_ENTRIES_OFF     0x0c
#define DROP_TARGET_ENTRY_STRIDE    0x10
#define DROP_TARGET_HOME            0
#define DROP_TARGET_FIRST           1
#define DROP_TARGET_LAST            25

#define LINE_G2_SIZE                0x14
#define LINE_G2_CODE                0x50
#define RING_SEGMENTS               8
#define PRIM_BUDGET_RESERVE         0x200
#define LABEL_PRIM_BUDGET           0x80

#define GULP_MARKER_BIRD_COUNT      3
#define GULP_MARKER_NO_BIRD         0xff

static const uint8_t bird_ring_color[GULP_MARKER_BIRD_COUNT][3] = {
    { 255, 0, 0 },
    { 0, 255, 0 },
    { 0, 0, 255 },
};

static const uint8_t default_ring_color[3] = { 255, 220, 68 };

static uint8_t claimed_drop_bird[DROP_TARGET_LAST + 1];

static const int ring_cos[RING_SEGMENTS] = {
    4096, 2896, 0, -2896, -4096, -2896, 0, 2896,
};
static const int ring_sin[RING_SEGMENTS] = {
    0, 2896, 4096, 2896, 0, -2896, -4096, -2896,
};

typedef struct {
    int show_drop_markers;
    int show_drop_labels;
    int marker_radius;
    int label_y_offset;
    int label_x_offset_single;
    int label_x_offset_double;
    int label_color_drop;
} GulpMarkerConfig;

static const GulpMarkerConfig gulpMarkerConfigDefault = {
    .show_drop_markers      = 1,
    .show_drop_labels       = 1,
    .marker_radius          = 900,
    .label_y_offset         = -4,
    .label_x_offset_single  = 6,
    .label_x_offset_double  = 12,
    .label_color_drop       = 3,
};

static const GulpMarkerConfig *marker_config = &gulpMarkerConfigDefault;

void gulp_markers_clear_claims(void) {
    int index;

    for (index = 0; index <= DROP_TARGET_LAST; index++) {
        claimed_drop_bird[index] = GULP_MARKER_NO_BIRD;
    }
}

void gulp_markers_claim_drop(int bird_index, int drop_index) {
    if (bird_index < 0 || bird_index >= GULP_MARKER_BIRD_COUNT) {
        return;
    }
    if (drop_index < DROP_TARGET_FIRST || drop_index > DROP_TARGET_LAST) {
        return;
    }
    claimed_drop_bird[drop_index] = (uint8_t)bird_index;
}

static const uint8_t *ring_color_for_drop(int drop_index) {
    uint8_t bird_index;

    if (drop_index < DROP_TARGET_FIRST || drop_index > DROP_TARGET_LAST) {
        return default_ring_color;
    }

    bird_index = claimed_drop_bird[drop_index];
    if (bird_index >= GULP_MARKER_BIRD_COUNT) {
        return default_ring_color;
    }

    return bird_ring_color[bird_index];
}

static int32_t *get_path_table(void) {
    int32_t path_table = *(int32_t *)(gulpBird0Data + 0x0c);
    if (path_table == 0) {
        return NULL;
    }
    return (int32_t *)path_table;
}

static void read_drop_xy(int32_t *path_table, int index, int32_t *x, int32_t *y) {
    uint8_t *entry = (uint8_t *)path_table + DROP_TARGET_ENTRIES_OFF
        + index * DROP_TARGET_ENTRY_STRIDE;
    *x = *(int32_t *)(entry + 0);
    *y = *(int32_t *)(entry + 4);
}

static int prim_buffer_remaining(void) {
    return (int)(primitiveBuffer_end - primitiveBuffer_next);
}

static int project_drop_center(int32_t x, int32_t y, int *screen) {
    int world[3];

    world[0] = x;
    world[1] = y;
    world[2] = GULP_ARENA_FLOOR_Z;
    WorldToScreenVec3(screen, world, 0);
    return screen[2] > 0;
}

static void insert_line_g2(
    short x0, short y0, short x1, short y1,
    uint8_t r, uint8_t g, uint8_t b
) {
    uint8_t *pb;

    if (prim_buffer_remaining() < LINE_G2_SIZE + PRIM_BUDGET_RESERVE) {
        return;
    }

    pb = primitiveBuffer_next;
    pb[0] = 0;
    pb[1] = 0;
    pb[2] = 0;
    pb[3] = 4;
    pb[7] = LINE_G2_CODE;
    *(int16_t *)(pb + 8) = x0;
    *(int16_t *)(pb + 10) = y0;
    *(int16_t *)(pb + 0x10) = x1;
    *(int16_t *)(pb + 0x12) = y1;
    pb[4] = r;
    pb[5] = g;
    pb[6] = b;
    pb[0xc] = r;
    pb[0xd] = g;
    pb[0xe] = b;
    PrimitiveBuffer_Insert((uint32_t *)pb);
    primitiveBuffer_next = pb + LINE_G2_SIZE;
}

static void draw_world_ring(
    int32_t wx, int32_t wy, int32_t wz, int radius,
    uint8_t r, uint8_t g, uint8_t b
) {
    int world[3];
    int screen[3];
    int px[RING_SEGMENTS];
    int py[RING_SEGMENTS];
    int ok[RING_SEGMENTS];
    int i;
    int ni;

    for (i = 0; i < RING_SEGMENTS; i++) {
        world[0] = wx + ((radius * ring_cos[i]) >> 12);
        world[1] = wy + ((radius * ring_sin[i]) >> 12);
        world[2] = wz;
        WorldToScreenVec3(screen, world, 0);
        px[i] = screen[0];
        py[i] = screen[1];
        ok[i] = screen[2] > 0;
    }

    for (i = 0; i < RING_SEGMENTS; i++) {
        ni = (i + 1) & (RING_SEGMENTS - 1);
        if (!ok[i] || !ok[ni]) {
            continue;
        }
        insert_line_g2(
            (short)px[i], (short)py[i],
            (short)px[ni], (short)py[ni],
            r, g, b
        );
    }
}

static void draw_drop_label(int index, int sx, int sy) {
    int x_offset;

    if (!marker_config->show_drop_labels) {
        return;
    }

    if (prim_buffer_remaining() < LABEL_PRIM_BUDGET + PRIM_BUDGET_RESERVE) {
        return;
    }

    x_offset = (index >= 10)
        ? marker_config->label_x_offset_double
        : marker_config->label_x_offset_single;

    DrawNumberSmall(
        index,
        sx - x_offset,
        (short)(sy + marker_config->label_y_offset),
        marker_config->label_color_drop
    );
}

static void draw_drop_marker(int index, int32_t x, int32_t y) {
    int screen[3];
    const uint8_t *color;

    if (!project_drop_center(x, y, screen)) {
        return;
    }

    color = ring_color_for_drop(index);
    draw_world_ring(
        x, y, GULP_ARENA_FLOOR_Z, marker_config->marker_radius,
        color[0], color[1], color[2]
    );

    draw_drop_label(index, screen[0], screen[1]);
}

void gulp_draw_drop_markers(void) {
    int32_t *path_table;
    uint16_t table_count;
    int last;
    int index;
    int32_t x;
    int32_t y;

    if (!marker_config->show_drop_markers) {
        return;
    }

    path_table = get_path_table();
    if (!path_table) {
        return;
    }

    table_count = *(uint16_t *)path_table;
    last = DROP_TARGET_LAST;
    if (table_count > 0 && table_count - 1 < last) {
        last = table_count - 1;
    }

    for (index = DROP_TARGET_FIRST; index <= last; index++) {
        read_drop_xy(path_table, index, &x, &y);
        draw_drop_marker(index, x, y);
    }
}

void gulp_select_render_hook(void) {
    SelectRender(GULP_RENDER_GAMEPLAY_FLAGS);
    if (GAME_gameState == 0 && GAME_level_id == GULP_FIGHT_LEVEL_ID) {
        gulp_draw_drop_markers();
    }
}

__attribute__((naked)) void gulp_select_render_hook_trampoline(void) {
    asm volatile (
        ".set noreorder\n"
        "j gulp_select_render_hook\n"
        "li $a0, 0x3d\n"
        ".set reorder\n"
    );
}
