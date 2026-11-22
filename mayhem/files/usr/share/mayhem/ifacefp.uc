#!/usr/bin/ucode
// Mayhem: does an interface that came up change what the configuration was
// built from? Exit 0 when it is the same (the provider's DNS servers, the
// router's addresses, IPv6, the tunnels' interfaces), 1 when not or when the
// last build wrote nothing (runtime.fp of gen.uc).
//   ifacefp.uc

'use strict';

import { readfile } from 'fs';
import { RUN_DIR } from 'mayhem.const';

const was = readfile(`${RUN_DIR}/runtime.fp`);

exit(was != null && trim(was) == require('mayhem.model').runtime_fp() ? 0 : 1);
