package dnspolicy

import (
	"net"
	"syscall"
)

// Resolver transport sockets must bypass both Mayhem's interception and its
// policy sets, just like Xray's own outbound sockets. The service runs as root.
func upstreamDialer() net.Dialer {
	return net.Dialer{Control: func(network, address string, c syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err == nil && net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback() {
			return nil
		}
		var sockErr error
		err = c.Control(func(fd uintptr) {
			sockErr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_MARK, 0x1000000)
		})
		if err != nil {
			return err
		}
		return sockErr
	}}
}
