// Priorities board (board.home.example.com): the iframe takes the board's own height,
// so folding/unfolding lanes never leaves a gap or an inner scrollbar. Added 2026-11-05.
window.addEventListener("message", function (e) {
  if (e.origin !== "https://board.home.example.com" || !e.data || e.data.type !== "board-height") return;
  var h = Math.max(80, Math.min(4000, Number(e.data.h) || 0));
  document.querySelectorAll('iframe[src^="https://board.home.example.com/"]').forEach(function (f) {
    f.style.height = h + "px";
  });
});
