# FileHub test server: SFTP (OpenSSH), FTPS with LIST (vsftpd), FTPS with MLSD (Pure-FTPd),
# FTPS with ProFTPD/mod_tls (like All-inkl) and a plain FTP server that FileHub must refuse.
# Local only, ports on 127.0.0.1 only (scripts/testserver.sh). Credentials are test values.
FROM httpd:2.4

# vsftpd, pure-ftpd and proftpd conflict as packages: pure-ftpd and proftpd are only unpacked
# (their libraries are installed normally).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server vsftpd openssl libcap2 libsodium23 iproute2 \
      libacl1 libhiredis1.1.0 libidn2-0 libmemcached11t64 libmemcachedutil2t64 libpcre2-posix3 libncursesw6 \
 && cd /tmp && apt-get download pure-ftpd pure-ftpd-common proftpd-core proftpd-mod-crypto \
 && dpkg -x pure-ftpd_*.deb /tmp/pf && cp /tmp/pf/usr/sbin/pure-ftpd /usr/sbin/pure-ftpd \
 && dpkg -x proftpd-core_*.deb / && dpkg -x proftpd-mod-crypto_*.deb / \
 && rm -rf /tmp/pf /tmp/*.deb /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash filehub \
 && echo 'filehub:filehub-test-pw' | chpasswd \
 && mkdir -p /run/sshd /var/run/vsftpd/empty /etc/ssl/filehub /home/filehub/.ssh \
 && chown filehub:filehub /home/filehub/.ssh && chmod 700 /home/filehub/.ssh

# Own test CA and a server certificate for "localhost" only (127.0.0.1 must fail as a wrong
# name). scripts/testserver.sh copies the CA to build/test/ca.pem; only the check runs trust it.
RUN cd /etc/ssl/filehub \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=FileHub Test CA" \
      -keyout ca.key -out ca.pem \
 && openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr \
 && printf 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n' > ext.cnf \
 && openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
      -extfile ext.cnf -out server.pem \
 && mkdir -p /etc/ssl/private \
 && cat server.key server.pem > /etc/ssl/private/pure-ftpd.pem \
 && chmod 600 /etc/ssl/private/pure-ftpd.pem server.key

COPY sshd_config /etc/ssh/sshd_config.d/filehub.conf
COPY vsftpd-tls.conf /etc/vsftpd-tls.conf
COPY vsftpd-plain.conf /etc/vsftpd-plain.conf
COPY proftpd-tls.conf /etc/proftpd-tls.conf
COPY start.sh /start.sh
RUN chmod +x /start.sh && ssh-keygen -A

EXPOSE 2222 2121 2122 2123 2124
CMD ["/start.sh"]
