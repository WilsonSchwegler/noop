# Attribution

WarbFit is independent, local-first interoperability software for fitness
tracker hardware the user owns. It is not affiliated with, endorsed by, or
connected to any fitness tracker manufacturer.

The app builds on open-source interoperability research and libraries:

- `johnmiddleton12/my-whoop`: protocol and storage research that informed the
  internal `WhoopProtocol` and `WhoopStore` Swift packages.
- `b-nnett/goose`: protocol research for newer strap hardware families.
- `GRDB.swift`: SQLite persistence used by the Swift local store.
- `ZIPFoundation`: local archive handling for imports and backups.

WarbFit contains no proprietary application binaries, firmware, branded artwork,
account credentials, API secrets, or server endpoints from any fitness tracker
manufacturer. It operates only with the user's own device and data.
