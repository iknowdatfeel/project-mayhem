#!/usr/bin/ucode
// Mayhem: moves fallback chains along once (mayhem.fallback). health.uc runs
// the same every 20 s; this is for a run apart: after a reload, a choice on
// the dashboard.
//
//   fallback.uc

'use strict';

import * as fallback from 'mayhem.fallback';

fallback.run();
