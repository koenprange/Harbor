# Third-party software

Harbor uses Transmission as a separate executable controlled through its local RPC API. Harbor itself is licensed under GNU GPL version 3 (`GPL-3.0-only`); the components below retain their own licenses and copyrights.

| Component | License |
| --- | --- |
| Transmission | GPL version 2 or 3; this distribution uses the GPL version 3 option |
| libevent | BSD 3-Clause |
| libpsl | MIT |
| Public Suffix List data included by libpsl | Mozilla Public License 2.0 |
| miniupnpc | BSD 3-Clause |
| GNU libiconv library | LGPL version 2 or later |

The component directories include upstream license and author notices, including those for Transmission's embedded dependencies. GNU libiconv's command-line tools are not bundled.

The Public Suffix List is included without modification. Its source is in the libpsl source archive distributed with the release, under `list/public_suffix_list.dat`. Its license is available at https://mozilla.org/MPL/2.0/.

Exact versions, upstream source URLs and SHA-256 checksums are recorded in `manifest.json`. The corresponding source archives and build recipes accompany the application download. Library load paths are adjusted for a relocatable macOS app; no changes are made to the engine source.
