// Commands - shared contract between presentation (views) and domain (CommandHandler)
//
// Views produce Commands from user input.
// CommandHandler in apply.zig consumes and executes them.
//
// Note: Uses own ID type to avoid module dependency issues.
// Domain code should convert to/from entity.ID as needed.

// pub const ID = struct {
//     index: u32,
//     generation: u32,
// };

const entity = @import("entity.zig");
pub const ID = entity.ID;

pub const Command = union(enum) {
    // Game flow
    start_game: void,
    pause_game: void,
    resume_game: void,

    // Combat - card selection
    play_card: ID,
    cancel_card: ID,
    end_turn: void,
    commit_turn: void,

    // Combat - commit phase (Focus spending, 1F each)
    commit_withdraw: ID, // remove card from play, refund stamina
    commit_add: ID, // add card from hand as new play
    commit_stack: struct { card_id: ID, target_play_index: usize }, // reinforce existing play
    commit_done: void, // finish commit phase

    // Combat - targeting
    select_target: struct { target_id: ID },
    cancel_targeting: void,

    // Combat - reactions
    play_reaction: struct { card_id: ID, in_response_to: usize },
    decline_reaction: void,

    // Navigation
    open_inventory: void,
    close_overlay: void,
};
