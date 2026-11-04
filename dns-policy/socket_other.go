//go:build !linux

package dnspolicy

import "net"

// Host-side tests use ordinary loopback sockets; production builds target Linux.
func upstreamDialer() net.Dialer { return net.Dialer{} }
