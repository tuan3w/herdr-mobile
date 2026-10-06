// GENERATED from the Unicode character names of U+2500-259F (box drawing and
// block elements). Do not edit by hand.
//
// One entry per code point, indexed by `codePoint - 0x2500`. Layout of an entry
// (decoded in `box_drawing.dart`):
//
//   bits 0-7   arm weights: left (0-1), right (2-3), up (4-5), down (6-7);
//              0 none, 1 light, 2 heavy, 3 double
//   bits 8-10  kind: 1 arms, 2 dashes, 3 arc, 4 diagonals, 5 rectangle,
//              6 shade, 7 quadrants
//   bits 11+   kind parameter: dash count minus 2; diagonal mask (1 = `/`,
//              2 = `\`); rectangle x0, y0, x1, y1 in eighths (4 bits each);
//              shade quarters (1-3); quadrant mask (1 upper left, 2 upper
//              right, 4 lower left, 8 lower right)

const boxGlyphCodes = <int>[
  0x0000105, // U+2500 ─ Light Horizontal
  0x000010a, // U+2501 ━ Heavy Horizontal
  0x0000150, // U+2502 │ Light Vertical
  0x00001a0, // U+2503 ┃ Heavy Vertical
  0x0000a05, // U+2504 ┄ Light Triple Dash Horizontal
  0x0000a0a, // U+2505 ┅ Heavy Triple Dash Horizontal
  0x0000a50, // U+2506 ┆ Light Triple Dash Vertical
  0x0000aa0, // U+2507 ┇ Heavy Triple Dash Vertical
  0x0001205, // U+2508 ┈ Light Quadruple Dash Horizontal
  0x000120a, // U+2509 ┉ Heavy Quadruple Dash Horizontal
  0x0001250, // U+250A ┊ Light Quadruple Dash Vertical
  0x00012a0, // U+250B ┋ Heavy Quadruple Dash Vertical
  0x0000144, // U+250C ┌ Light Down And Right
  0x0000148, // U+250D ┍ Down Light And Right Heavy
  0x0000184, // U+250E ┎ Down Heavy And Right Light
  0x0000188, // U+250F ┏ Heavy Down And Right
  0x0000141, // U+2510 ┐ Light Down And Left
  0x0000142, // U+2511 ┑ Down Light And Left Heavy
  0x0000181, // U+2512 ┒ Down Heavy And Left Light
  0x0000182, // U+2513 ┓ Heavy Down And Left
  0x0000114, // U+2514 └ Light Up And Right
  0x0000118, // U+2515 ┕ Up Light And Right Heavy
  0x0000124, // U+2516 ┖ Up Heavy And Right Light
  0x0000128, // U+2517 ┗ Heavy Up And Right
  0x0000111, // U+2518 ┘ Light Up And Left
  0x0000112, // U+2519 ┙ Up Light And Left Heavy
  0x0000121, // U+251A ┚ Up Heavy And Left Light
  0x0000122, // U+251B ┛ Heavy Up And Left
  0x0000154, // U+251C ├ Light Vertical And Right
  0x0000158, // U+251D ┝ Vertical Light And Right Heavy
  0x0000164, // U+251E ┞ Up Heavy And Right Down Light
  0x0000194, // U+251F ┟ Down Heavy And Right Up Light
  0x00001a4, // U+2520 ┠ Vertical Heavy And Right Light
  0x0000168, // U+2521 ┡ Down Light And Right Up Heavy
  0x0000198, // U+2522 ┢ Up Light And Right Down Heavy
  0x00001a8, // U+2523 ┣ Heavy Vertical And Right
  0x0000151, // U+2524 ┤ Light Vertical And Left
  0x0000152, // U+2525 ┥ Vertical Light And Left Heavy
  0x0000161, // U+2526 ┦ Up Heavy And Left Down Light
  0x0000191, // U+2527 ┧ Down Heavy And Left Up Light
  0x00001a1, // U+2528 ┨ Vertical Heavy And Left Light
  0x0000162, // U+2529 ┩ Down Light And Left Up Heavy
  0x0000192, // U+252A ┪ Up Light And Left Down Heavy
  0x00001a2, // U+252B ┫ Heavy Vertical And Left
  0x0000145, // U+252C ┬ Light Down And Horizontal
  0x0000146, // U+252D ┭ Left Heavy And Right Down Light
  0x0000149, // U+252E ┮ Right Heavy And Left Down Light
  0x000014a, // U+252F ┯ Down Light And Horizontal Heavy
  0x0000185, // U+2530 ┰ Down Heavy And Horizontal Light
  0x0000186, // U+2531 ┱ Right Light And Left Down Heavy
  0x0000189, // U+2532 ┲ Left Light And Right Down Heavy
  0x000018a, // U+2533 ┳ Heavy Down And Horizontal
  0x0000115, // U+2534 ┴ Light Up And Horizontal
  0x0000116, // U+2535 ┵ Left Heavy And Right Up Light
  0x0000119, // U+2536 ┶ Right Heavy And Left Up Light
  0x000011a, // U+2537 ┷ Up Light And Horizontal Heavy
  0x0000125, // U+2538 ┸ Up Heavy And Horizontal Light
  0x0000126, // U+2539 ┹ Right Light And Left Up Heavy
  0x0000129, // U+253A ┺ Left Light And Right Up Heavy
  0x000012a, // U+253B ┻ Heavy Up And Horizontal
  0x0000155, // U+253C ┼ Light Vertical And Horizontal
  0x0000156, // U+253D ┽ Left Heavy And Right Vertical Light
  0x0000159, // U+253E ┾ Right Heavy And Left Vertical Light
  0x000015a, // U+253F ┿ Vertical Light And Horizontal Heavy
  0x0000165, // U+2540 ╀ Up Heavy And Down Horizontal Light
  0x0000195, // U+2541 ╁ Down Heavy And Up Horizontal Light
  0x00001a5, // U+2542 ╂ Vertical Heavy And Horizontal Light
  0x0000166, // U+2543 ╃ Left Up Heavy And Right Down Light
  0x0000169, // U+2544 ╄ Right Up Heavy And Left Down Light
  0x0000196, // U+2545 ╅ Left Down Heavy And Right Up Light
  0x0000199, // U+2546 ╆ Right Down Heavy And Left Up Light
  0x000016a, // U+2547 ╇ Down Light And Up Horizontal Heavy
  0x000019a, // U+2548 ╈ Up Light And Down Horizontal Heavy
  0x00001a6, // U+2549 ╉ Right Light And Left Vertical Heavy
  0x00001a9, // U+254A ╊ Left Light And Right Vertical Heavy
  0x00001aa, // U+254B ╋ Heavy Vertical And Horizontal
  0x0000205, // U+254C ╌ Light Double Dash Horizontal
  0x000020a, // U+254D ╍ Heavy Double Dash Horizontal
  0x0000250, // U+254E ╎ Light Double Dash Vertical
  0x00002a0, // U+254F ╏ Heavy Double Dash Vertical
  0x000010f, // U+2550 ═ Double Horizontal
  0x00001f0, // U+2551 ║ Double Vertical
  0x000014c, // U+2552 ╒ Down Single And Right Double
  0x00001c4, // U+2553 ╓ Down Double And Right Single
  0x00001cc, // U+2554 ╔ Double Down And Right
  0x0000143, // U+2555 ╕ Down Single And Left Double
  0x00001c1, // U+2556 ╖ Down Double And Left Single
  0x00001c3, // U+2557 ╗ Double Down And Left
  0x000011c, // U+2558 ╘ Up Single And Right Double
  0x0000134, // U+2559 ╙ Up Double And Right Single
  0x000013c, // U+255A ╚ Double Up And Right
  0x0000113, // U+255B ╛ Up Single And Left Double
  0x0000131, // U+255C ╜ Up Double And Left Single
  0x0000133, // U+255D ╝ Double Up And Left
  0x000015c, // U+255E ╞ Vertical Single And Right Double
  0x00001f4, // U+255F ╟ Vertical Double And Right Single
  0x00001fc, // U+2560 ╠ Double Vertical And Right
  0x0000153, // U+2561 ╡ Vertical Single And Left Double
  0x00001f1, // U+2562 ╢ Vertical Double And Left Single
  0x00001f3, // U+2563 ╣ Double Vertical And Left
  0x000014f, // U+2564 ╤ Down Single And Horizontal Double
  0x00001c5, // U+2565 ╥ Down Double And Horizontal Single
  0x00001cf, // U+2566 ╦ Double Down And Horizontal
  0x000011f, // U+2567 ╧ Up Single And Horizontal Double
  0x0000135, // U+2568 ╨ Up Double And Horizontal Single
  0x000013f, // U+2569 ╩ Double Up And Horizontal
  0x000015f, // U+256A ╪ Vertical Single And Horizontal Double
  0x00001f5, // U+256B ╫ Vertical Double And Horizontal Single
  0x00001ff, // U+256C ╬ Double Vertical And Horizontal
  0x0000344, // U+256D ╭ Light Arc Down And Right
  0x0000341, // U+256E ╮ Light Arc Down And Left
  0x0000311, // U+256F ╯ Light Arc Up And Left
  0x0000314, // U+2570 ╰ Light Arc Up And Right
  0x0000c00, // U+2571 ╱ Light Diagonal Upper Right To Lower Left
  0x0001400, // U+2572 ╲ Light Diagonal Upper Left To Lower Right
  0x0001c00, // U+2573 ╳ Light Diagonal Cross
  0x0000101, // U+2574 ╴ Light Left
  0x0000110, // U+2575 ╵ Light Up
  0x0000104, // U+2576 ╶ Light Right
  0x0000140, // U+2577 ╷ Light Down
  0x0000102, // U+2578 ╸ Heavy Left
  0x0000120, // U+2579 ╹ Heavy Up
  0x0000108, // U+257A ╺ Heavy Right
  0x0000180, // U+257B ╻ Heavy Down
  0x0000109, // U+257C ╼ Light Left And Heavy Right
  0x0000190, // U+257D ╽ Light Up And Heavy Down
  0x0000106, // U+257E ╾ Heavy Left And Light Right
  0x0000160, // U+257F ╿ Heavy Up And Light Down
  0x2400500, // U+2580 ▀ Upper Half Block
  0x4438500, // U+2581 ▁ Lower One Eighth Block
  0x4430500, // U+2582 ▂ Lower One Quarter Block
  0x4428500, // U+2583 ▃ Lower Three Eighths Block
  0x4420500, // U+2584 ▄ Lower Half Block
  0x4418500, // U+2585 ▅ Lower Five Eighths Block
  0x4410500, // U+2586 ▆ Lower Three Quarters Block
  0x4408500, // U+2587 ▇ Lower Seven Eighths Block
  0x4400500, // U+2588 █ Full Block
  0x4380500, // U+2589 ▉ Left Seven Eighths Block
  0x4300500, // U+258A ▊ Left Three Quarters Block
  0x4280500, // U+258B ▋ Left Five Eighths Block
  0x4200500, // U+258C ▌ Left Half Block
  0x4180500, // U+258D ▍ Left Three Eighths Block
  0x4100500, // U+258E ▎ Left One Quarter Block
  0x4080500, // U+258F ▏ Left One Eighth Block
  0x4402500, // U+2590 ▐ Right Half Block
  0x0000e00, // U+2591 ░ Light Shade
  0x0001600, // U+2592 ▒ Medium Shade
  0x0001e00, // U+2593 ▓ Dark Shade
  0x0c00500, // U+2594 ▔ Upper One Eighth Block
  0x4403d00, // U+2595 ▕ Right One Eighth Block
  0x0002700, // U+2596 ▖ Quadrant Lower Left
  0x0004700, // U+2597 ▗ Quadrant Lower Right
  0x0000f00, // U+2598 ▘ Quadrant Upper Left
  0x0006f00, // U+2599 ▙ Quadrant Upper Left And Lower Left And Lower Right
  0x0004f00, // U+259A ▚ Quadrant Upper Left And Lower Right
  0x0003f00, // U+259B ▛ Quadrant Upper Left And Upper Right And Lower Left
  0x0005f00, // U+259C ▜ Quadrant Upper Left And Upper Right And Lower Right
  0x0001700, // U+259D ▝ Quadrant Upper Right
  0x0003700, // U+259E ▞ Quadrant Upper Right And Lower Left
  0x0007700, // U+259F ▟ Quadrant Upper Right And Lower Left And Lower Right
];
