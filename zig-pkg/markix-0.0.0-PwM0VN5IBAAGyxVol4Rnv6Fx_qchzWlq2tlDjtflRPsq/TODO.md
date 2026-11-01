# TODO

- [x] Separate the bookmarks and rss reader from the core
- [x] Benchmark worst-case frame generation against the configured limits.
      `zig build bench`. The incremental rows are the ones that matter: what a
      key press costs, not what a full redraw costs.
- [ ] Add pseudo-terminal integration tests for cleanup, resize, and rendering.
- [ ] Honour `list.scroll` in the widget-drawn path the way the DOM path now
      does, so a list drawn from a slice and a list drawn from mounted rows
      scroll by the same rule.
- [ ] Measure against ratatui and zigzag on the same workload. Neither ships a
      benchmark, so this means writing one for each and being explicit about
      what is and is not comparable.
