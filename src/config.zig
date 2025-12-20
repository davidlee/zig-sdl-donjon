pub const Config = struct {
    fps: usize,
    width: usize,
    height: usize,

    pub fn init() @This() {
        return @This(){
            .fps = 60,
            .width = 1080,
            .height = 860,
        };
    }
};
