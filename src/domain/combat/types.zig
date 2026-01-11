//! Combat type definitions - enums and FSM for combat state.
//!
//! This module contains pure type definitions with minimal dependencies.
//! Import via combat module: `const combat = @import("domain").combat;`

const zigfsm = @import("zigfsm");
const ai = @import("../ai.zig");

/// Who controls an agent's decisions.
pub const Director = union(enum) {
    player,
    ai: ai.Director,
};

/// Weapon reach and engagement distance categories.
/// Shorter/closer values are lower in enum order.
pub const Reach = enum {
    // Weapon reaches (shorter = lower)
    clinch,
    dagger,
    mace,
    sabre,
    longsword,
    spear,
    // Engagement distances (closer = lower)
    near,
    medium,
    far,
};

/// Axes along which advantage can be gained or lost in combat.
pub const AdvantageAxis = enum {
    balance,
    pressure,
    control,
    position,
};

/// How an agent draws cards during combat.
pub const DrawStyle = enum {
    shuffled_deck, // cards cycle through draw/hand/discard
    always_available, // cards in always_available pool, cooldown-based (stub)
    scripted, // behaviour tree selects from available cards (stub)
};

/// Possible outcomes when combat ends.
pub const CombatOutcome = enum {
    victory, // all enemies incapacitated
    defeat, // player incapacitated
    flee, // player escaped (stub)
    surrender, // negotiated end (stub)
};

/// Phases within a combat turn.
pub const TurnPhase = enum {
    stance_selection, // choose attack/defense/movement weighting
    draw_hand,
    player_card_selection, // choose cards in secret
    commit_phase, // reveal; vary or reinforce selections
    tick_resolution, // resolve committed actions
    player_reaction, // future: reaction windows
    animating,
};

/// Events that trigger turn phase transitions.
pub const TurnEvent = enum {
    confirm_stance, // stance_selection -> draw_hand
    begin_player_card_selection,
    begin_commit_phase,
    begin_tick_resolution,
    animate_resolution,
    redraw,
};

/// State machine for turn phase transitions.
pub const TurnFSM = zigfsm.StateMachine(TurnPhase, TurnEvent, .stance_selection);
