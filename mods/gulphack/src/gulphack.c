#include <stdint.h>

extern void              GAME_RenderGame(void);
extern int               RandomRangeInclusive(int min, int max);
extern int               GAME_gameState;
extern uint8_t           GAME_level_id;

#define GULP_FIGHT_LEVEL_ID 0x2e

typedef struct {
    int egg_hatch_timer_min;
    int egg_hatch_timer_max;
    int vulture_drop_delay_min;
    int vulture_drop_delay_max;
    int vulture_approach_timer_initial;
    int vulture_drop_angle_threshold;
    int vulture_drop_distance_threshold;
    int vulture_drop_population_gate;
    int random_rocket_lower;
    int random_bomb_upper_exclusive;
} GulpConfig;

static const GulpConfig gulpConfigDefault = {
    .egg_hatch_timer_min            = 0x78,
    .egg_hatch_timer_max            = 0xdc,
    .vulture_drop_delay_min         = 0x50,
    .vulture_drop_delay_max         = 0xb4,
    .vulture_approach_timer_initial = 0x03e8,
    .vulture_drop_angle_threshold   = 0x20,
    .vulture_drop_distance_threshold = 0x708,
    .vulture_drop_population_gate   = 6,
    .random_rocket_lower            = 81,
    .random_bomb_upper_exclusive    = 41,
};

static const GulpConfig gulpConfigCustom = {
    .egg_hatch_timer_min            = 0x78,
    .egg_hatch_timer_max            = 0xdc,
    .vulture_drop_delay_min         = 0x50,
    .vulture_drop_delay_max         = 0xb4,
    .vulture_approach_timer_initial = 0x03e8,
    .vulture_drop_angle_threshold   = 0x20,
    .vulture_drop_distance_threshold = 0x708,
    .vulture_drop_population_gate   = 6,
    .random_rocket_lower            = 81,
    .random_bomb_upper_exclusive    = 41,
};

static const GulpConfig *config = &gulpConfigCustom;

#define GULP_NUM_BIRDS       3
#define GULP_BIRD_SCRIPT_LEN 4

typedef enum {
    BARREL = 0,
    BOMB   = 1,
    ROCKET = 2,
} GulpWeapon;

typedef struct {
    uint8_t   targetIndex; // 1-25: which drop slot the vulture flies to
    GulpWeapon weapon;
} GulpDropScript;

//   rand <= 40           => bomb
//   40 < rand < 81       => barrel
//   rand >= 81           => rocket
static const int weapon_roll[3] = {
    [BARREL] = 41,
    [BOMB]   = 0,
    [ROCKET] = 81,
};

// drop_script[bird][N] is that bird's Nth drop (0-based, in its own sequence).
// Bird 0/1: N=0..3 map to cycles 1-4. Bird 2: N=0..1 map to cycles 3-4 only.
static const GulpDropScript drop_script[GULP_NUM_BIRDS][GULP_BIRD_SCRIPT_LEN] = {
    // Bird 0
    {
        {  7, BARREL },
        {  1, ROCKET },
        {  15, BARREL },
        { 25, ROCKET },
    },
    // Bird 1
    {
        {  5, BARREL },
        { 14, ROCKET },
        { 6, BOMB },
        { 10, ROCKET },
    },
    // Bird 2
    {
        { 16, ROCKET },
        { 11, ROCKET },
    },
};

static int hooks_installed = 0;

static const void * const bird_key[GULP_NUM_BIRDS] = {
    (const void *)0x80120e44,
    (const void *)0x80120c64,
    (const void *)0x80120e88,
};

static int bird_drop_count[GULP_NUM_BIRDS] = { 0, 0, 0 };

static int gulp_get_bird_index(const void *key) {
    for (int i = 0; i < GULP_NUM_BIRDS; i++) {
        if (bird_key[i] == key) {
            return i;
        }
    }
    return -1;
}

static void gulp_reset_bird_tracking(void) {
    for (int i = 0; i < GULP_NUM_BIRDS; i++) {
        bird_drop_count[i] = 0;
    }
}

// Replaces: jal RandomRangeInclusive at 0x80077490 (drop-target slot roll).
// vultureData is recovered from $s2 by gulp_target_hook_trampoline -- it is
// untouched by the replaced call (callee-saved register), so it reliably
// identifies which vulture is currently picking a target.
int gulp_target_hook(int min, int max, const void *vultureData) {
    int bird = gulp_get_bird_index(vultureData);
    if (bird >= 0 && bird_drop_count[bird] < GULP_BIRD_SCRIPT_LEN) {
        return drop_script[bird][bird_drop_count[bird]].targetIndex;
    }
    return RandomRangeInclusive(min, max);
}

// Replaces: jal RandomRangeInclusive at 0x80077838 (barrel/bomb/rocket roll).
// gulp_weapon_hook_trampoline recovers vultureMoby->data (== GulpVultureData*,
// same key space as the target hook above) from $s4 so both hooks agree on
// "which bird" this is. This is also where we advance that bird's script index,
// since the weapon roll happens exactly once per completed drop.
int gulp_weapon_hook(int min, int max, const void *vultureData) {
    int bird = gulp_get_bird_index(vultureData);
    if (bird >= 0 && bird_drop_count[bird] < GULP_BIRD_SCRIPT_LEN) {
        GulpWeapon w = drop_script[bird][bird_drop_count[bird]].weapon;
        bird_drop_count[bird]++;
        return weapon_roll[w];
    }
    return RandomRangeInclusive(min, max);
}

// Trampolines: the replaced jal sites don't pass the vulture pointer as an
// argument, but it's sitting in a callee-saved register at the call site. These
// naked stubs forward it as a 3rd argument ($a2) before jumping into the real
// (non-naked) C hook, which then follows the normal calling convention.
__attribute__((naked)) void gulp_target_hook_trampoline(void) {
    asm volatile (
        ".set noreorder\n"
        "move $a2, $s2\n"        // a2 = vultureData (GulpVultureData*)
        "j gulp_target_hook\n"
        "nop\n"
        ".set reorder\n"
    );
}

__attribute__((naked)) void gulp_weapon_hook_trampoline(void) {
    asm volatile (
        ".set noreorder\n"
        "lw $a2, 0($s4)\n"       // a2 = vultureMoby->data (GulpVultureData*, Moby::data is at offset 0)
        "j gulp_weapon_hook\n"
        "nop\n"
        ".set reorder\n"
    );
}

static void patch_u32(uint32_t *loc, uint32_t value) {
    *loc = value;
}

static void patch_jal(uint32_t *loc, uint32_t target) {
    *loc = ((target & 0x03ffffff) >> 2) | 0x0c000000;
}

static void patch_imm16(uint32_t *loc, int imm) {
    *loc = (*loc & 0xffff0000) | (imm & 0xffff);
}

static void gulp_apply_config_patches(const GulpConfig *cfg) {
    patch_imm16((uint32_t *)0x800779c8, cfg->egg_hatch_timer_min);
    patch_imm16((uint32_t *)0x800779d0, cfg->egg_hatch_timer_max);
    patch_imm16((uint32_t *)0x80077a24, cfg->vulture_drop_delay_min);
    patch_imm16((uint32_t *)0x80077a30, cfg->vulture_drop_delay_max);
    patch_imm16((uint32_t *)0x800772a0, cfg->vulture_approach_timer_initial);
    patch_imm16((uint32_t *)0x80077804, cfg->vulture_drop_angle_threshold);
    patch_imm16((uint32_t *)0x800777c0, cfg->vulture_drop_distance_threshold);
    patch_imm16((uint32_t *)0x80077618, cfg->vulture_drop_population_gate);
    patch_imm16((uint32_t *)0x8007799c, cfg->random_rocket_lower);
    patch_imm16((uint32_t *)0x800779a4, cfg->random_bomb_upper_exclusive);
}

static void gulp_install_hooks(void) {
    gulp_apply_config_patches(config);
    gulp_reset_bird_tracking();
    patch_jal((uint32_t *)0x80077490, (uint32_t)gulp_target_hook_trampoline);
    patch_jal((uint32_t *)0x80077838, (uint32_t)gulp_weapon_hook_trampoline);
    hooks_installed = 1;
}

void main_hook(void) {
    GAME_RenderGame();

    int in_gulp_fight = (GAME_gameState == 0) &&
                        (GAME_level_id == GULP_FIGHT_LEVEL_ID);

    if (in_gulp_fight) {
        if (!hooks_installed) {
            gulp_install_hooks();
        }
    } else {
        if (hooks_installed) {
            hooks_installed = 0;
        }
    }
}