#include <stdint.h>

extern void              GAME_RenderGame(void);
extern int               RandomRangeInclusive(int min, int max);
extern int               GAME_gameState;
extern uint8_t           GAME_level_id;
extern volatile uint32_t GULP_drop_counter;

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
    .egg_hatch_timer_max            = 170,
    .vulture_drop_delay_min         = 0x50,
    .vulture_drop_delay_max         = 0x50,
    .vulture_approach_timer_initial = 0x03e8,
    .vulture_drop_angle_threshold   = 0x20,
    .vulture_drop_distance_threshold = 0x708,
    .vulture_drop_population_gate   = 6,
    .random_rocket_lower            = 81,
    .random_bomb_upper_exclusive    = 41,
};

static const GulpConfig *s_config = &gulpConfigCustom;

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

//   rand <= 40           => bomb
//   40 < rand < 81       => barrel
//   rand >= 81           => rocket
static const int s_weapon_roll[3] = {
    [BARREL] = 41,
    [BOMB]   = 0,
    [ROCKET] = 81,
};

static const GulpDropScript s_script[GULP_SCRIPT_LEN] = {
    {  4, BARREL },
    { 6, BARREL   },
    
    {  8, ROCKET },
    { 24, ROCKET },

    {  3, BARREL   },
    { 11, ROCKET },
    {  23, BARREL },

    { 25, ROCKET   },
    {  3, BARREL },
    {  2, BARREL },
};

static int s_hooks_installed = 0;

int gulp_random_drop_target_hook(int min, int max) {
    if (GULP_drop_counter < GULP_SCRIPT_LEN) {
        return s_script[GULP_drop_counter].targetIndex;
    }
    return RandomRangeInclusive(min, max);
}

int gulp_random_weapon_hook(int min, int max) {
    if (GULP_drop_counter < GULP_SCRIPT_LEN) {
        return s_weapon_roll[s_script[GULP_drop_counter].weapon];
    }
    return RandomRangeInclusive(min, max);
}

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
    patch_u32((uint32_t *)0x8007729c, 0x00000000); // NOP the drop counter reset
    patch_jal((uint32_t *)0x80077490, (uint32_t)gulp_random_drop_target_hook);
    patch_jal((uint32_t *)0x80077838, (uint32_t)gulp_random_weapon_hook);
    s_hooks_installed = 1;
}

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
