#include <stdint.h>

extern void    GAME_RenderGame(void);
extern int     RandomRangeInclusive(int min, int max);
extern int     GAME_gameState;
extern uint8_t GAME_level_id;

#define GULP_FIGHT_LEVEL_ID 0x2e

// Keep in sync with gulp-script.lua default_config / custom_config + ADDR table.
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
    .egg_hatch_timer_max            = 0x78,
    .vulture_drop_delay_min         = 0x0,
    .vulture_drop_delay_max         = 0x0,
    .vulture_approach_timer_initial = 0x03e8,
    .vulture_drop_angle_threshold   = 0x20,
    .vulture_drop_distance_threshold = 0x708,
    .vulture_drop_population_gate   = 6,
    .random_rocket_lower            = 81,
    .random_bomb_upper_exclusive    = 41,
};

static const GulpConfig *s_config = &gulpConfigCustom;

// -----------------------------------------------------------------------
// Script table
// -----------------------------------------------------------------------

#define GULP_SCRIPT_LEN 10

typedef enum {
    BARREL = 0,
    BOMB   = 1,
    ROCKET = 2,
} GulpWeapon;

typedef struct {
    uint8_t   targetIndex; // 1-25: which drop slot the vulture flies to
    GulpWeapon weapon;
} GulpDropScript;

// Weapon encoding: the existing random branch uses s7 value ranges
//   s7 < 0x29          => barrel (0x196)
//   0x29 <= s7 < 0x51  => bomb   (0x197)
//   s7 >= 0x51         => rocket (0x198)
static const int s_weapon_roll[3] = { 0x00, 0x29, 0x51 };

static const GulpDropScript s_script[GULP_SCRIPT_LEN] = {
    {  5, BARREL },
    { 7, BARREL   },
    
    {  11, ROCKET },
    { 23, ROCKET },

    {  20, BARREL   },
    { 15, BARREL },
    {  16, ROCKET },

    { 25, ROCKET   },
    {  11, ROCKET },
    {  10, ROCKET },
};

// -----------------------------------------------------------------------
// State
// -----------------------------------------------------------------------

static int      s_hooks_installed = 0;
static uint32_t s_drop_idx        = 0;

// -----------------------------------------------------------------------
// Hook functions (called in place of RandomRangeInclusive in the overlay)
// -----------------------------------------------------------------------

// Replaces: jal RandomRangeInclusive at 0x80077490
// Context:  a0=0, a1=count; return value is used as randomStart for the
//           linear-probe target selection loop. Returning the desired
//           targetIndex causes the loop to pick it on its first probe.
int gulp_target_hook(int a0, int count) {
    if (s_drop_idx < GULP_SCRIPT_LEN) {
        return s_script[s_drop_idx].targetIndex - 1;
    }
    return RandomRangeInclusive(a0, count);
}

// Replaces: jal RandomRangeInclusive at 0x80077838
// Context:  a0=0, a1=0x64; return value (s7) drives the barrel/bomb/rocket
//           branch. We also advance s_drop_idx here — this fires when an egg
//           actually spawns, which is the definitive "one drop happened" event.
int gulp_weapon_hook(int a0, int a1) {
    if (s_drop_idx < GULP_SCRIPT_LEN) {
        int roll = s_weapon_roll[s_script[s_drop_idx].weapon];
        s_drop_idx++;
        return roll;
    }
    return RandomRangeInclusive(a0, a1);
}

// -----------------------------------------------------------------------
// Patch installation
// -----------------------------------------------------------------------

static void patch_u32(uint32_t *loc, uint32_t value) {
    *loc = value;
}

static void patch_jal(uint32_t *loc, uint32_t target) {
    *loc = ((target & 0x03ffffff) >> 2) | 0x0c000000;
}

static uint32_t encode_addiu(unsigned rt, unsigned rs, int imm) {
    return 0x24000000 | (rs << 21) | (rt << 16) | (imm & 0xffff);
}

static uint32_t encode_slti(unsigned rt, unsigned rs, int imm) {
    return 0x28000000 | (rs << 21) | (rt << 16) | (imm & 0xffff);
}

static void gulp_apply_config_patches(const GulpConfig *cfg) {
    patch_u32((uint32_t *)0x800779c8, encode_addiu(4, 0, cfg->egg_hatch_timer_min));
    patch_u32((uint32_t *)0x800779d0, encode_addiu(5, 0, cfg->egg_hatch_timer_max));
    patch_u32((uint32_t *)0x80077a24, encode_addiu(4, 0, cfg->vulture_drop_delay_min));
    patch_u32((uint32_t *)0x80077a30, encode_addiu(5, 0, cfg->vulture_drop_delay_max));
    patch_u32((uint32_t *)0x800772a0, encode_addiu(2, 0, cfg->vulture_approach_timer_initial));
    patch_u32((uint32_t *)0x80077804, encode_slti(2, 2, cfg->vulture_drop_angle_threshold));
    patch_u32((uint32_t *)0x800777c0, encode_slti(2, 2, cfg->vulture_drop_distance_threshold));
    patch_u32((uint32_t *)0x80077618, encode_slti(2, 16, cfg->vulture_drop_population_gate));
    patch_u32((uint32_t *)0x8007799c, encode_slti(2, 23, cfg->random_rocket_lower));
    patch_u32((uint32_t *)0x800779a4, encode_slti(2, 23, cfg->random_bomb_upper_exclusive));
}

static void gulp_install_hooks(void) {
    gulp_apply_config_patches(s_config);
    patch_jal((uint32_t *)0x80077490, (uint32_t)gulp_target_hook);
    patch_jal((uint32_t *)0x80077838, (uint32_t)gulp_weapon_hook);
    s_hooks_installed = 1;
    s_drop_idx        = 0;
}

// -----------------------------------------------------------------------
// Main hook — called every frame in place of the GAME_RenderGame jal
// at 0x80011afc in the main exe
// -----------------------------------------------------------------------

void main_hook(void) {
    GAME_RenderGame();

    int in_gulp_fight = (GAME_gameState == 0) &&
                        (GAME_level_id == GULP_FIGHT_LEVEL_ID);

    if (in_gulp_fight) {
        if (!s_hooks_installed) {
            gulp_install_hooks();
        }
    } else {
        if (s_hooks_installed) {
            s_hooks_installed = 0;
        }
    }
}
