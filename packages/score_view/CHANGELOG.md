## 0.1.0

- First version, moved out of Stringlings: the engraving layer.
  `VerovioEngraver` and `EngravedScore` (with its JSON form for the disk
  cache, whose build stamp is now `engraveCacheStamp`), `staff_zoom`, the
  section line planner, section engraving, print pagination, and the shared
  system-break mechanics (`insertBreaksAtPositions`, `systemStartPositions`,
  `AttrState`, `insertPrintBreak`, `hidePreamble`).
