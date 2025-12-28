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
    play_card: struct { card_id: ID },
    cancel_card: struct { card_id: ID },
    end_turn: void,

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
