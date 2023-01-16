# ViMouse
Control mouse cursor using keyboard like the Vim keybind ;)

This is for Mac OS.
ViMouse introduce your Mac two modes Normal and Input Mode such like the Vim.
After you start up the ViMouse, the indigator will appear at the menu bar.
When Normal mode, the menu item is highlighted and you can controll cursor.
When Input mode, you can input any key except `^ ;` or `<fn> ;` that is the mode switch.

NOTE:
This product is tuned up for me, so I recommend you to see the source and adjust parameters or key mapping.

## Key mapping in Normal mode
* `h`, `j`, `k`, `l`: acts as you know in normal mode.
* `i`, `<英数>`, `<かな>`: switch to Input mode
* `<space>`: Left click
* `n`: Middle click
* `;`: Right click
* `a`: Very slow cursor speed
* `s`: Slow cursor speed
* `d`: Fast cursor speed
* `f`: Very fast cursor speed
* `g`: Acts as mouse wheel. Use combined with `h`,`j`,`k`,`l` and `a`, `s`, `d`, `f`.
* `y`: Yank
* `p`: Paste
* `u`: Undo

## Key mapping in Input mode
* `^ ;`, `<fn> ;`: switch to Normal mode;
* `^ h`, `^j`, `^k`, `^l`: acts as arrow keys
