#!/bin/bash
set -e
/usr/sbin/sshd
/usr/sbin/vsftpd /etc/vsftpd-tls.conf &
/usr/sbin/vsftpd /etc/vsftpd-plain.conf &
/usr/sbin/proftpd -n -c /etc/proftpd-tls.conf &
# Pure-FTPd: TLS required (-Y 2), MLSD, everyone jailed in their home folder (-A).
exec /usr/sbin/pure-ftpd -l unix -E -A -Y 2 -S 0.0.0.0,2122 -p 30000:30009 -P 127.0.0.1
