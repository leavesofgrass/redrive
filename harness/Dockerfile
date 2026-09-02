# redrive "fake tablet": Debian slim imitating a reMarkable (Dropbear without SFTP,
# BusyBox userland in front of GNU tools, a systemctl shim and a mock of the USB web UI).
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    FAKE_PROFILE=paperpro-3.27

# dropbear-bin: sshd without scp/sftp-server (like the tablet).
# openssh-client: provides /usr/bin/scp for the REMOTE side of a legacy "scp -O" copy only.
# busybox-static: the applets that shadow GNU tools for every ssh command (see rmsh).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        dropbear-bin openssh-client busybox-static python3 iproute2 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /usr/local/busybox \
 && busybox --install -s /usr/local/busybox \
 && mkdir -p /home/root/.ssh \
             /home/root/.local/share/remarkable/xochitl \
             /home/root/.config/remarkable \
             /opt/fake-tablet/fixtures/rm \
             /etc/dropbear /run \
 && chmod 755 /home/root && chmod 700 /home/root/.ssh

COPY rmsh systemctl xochitl-fake.sh /usr/local/bin/
COPY entrypoint.sh gen-sample-xochitl.py mock-webui.py /opt/fake-tablet/
COPY fixtures/ /opt/fake-tablet/fixtures/

# Normalise line endings (a Windows checkout may have CRLF), make scripts executable,
# register rmsh as a login shell (dropbear checks /etc/shells), move root's home and
# shell, set the developer password, and fetch the .rm fixtures if the host did not.
RUN for f in /usr/local/bin/rmsh /usr/local/bin/systemctl /usr/local/bin/xochitl-fake.sh \
             /opt/fake-tablet/entrypoint.sh /opt/fake-tablet/gen-sample-xochitl.py \
             /opt/fake-tablet/mock-webui.py; do \
        sed -i 's/\r$//' "$f" && chmod 755 "$f"; \
    done \
 && echo /usr/local/bin/rmsh >> /etc/shells \
 && awk -F: 'BEGIN{OFS=":"} $1=="root"{$6="/home/root"; $7="/usr/local/bin/rmsh"} {print}' /etc/passwd > /etc/passwd.new \
 && mv /etc/passwd.new /etc/passwd \
 && grep '^root:' /etc/passwd \
 && echo 'root:fake' | chpasswd -c SHA512 \
 && (python3 /opt/fake-tablet/gen-sample-xochitl.py --fetch-only --fixtures /opt/fake-tablet/fixtures/rm || true)

EXPOSE 22 80
ENTRYPOINT ["/opt/fake-tablet/entrypoint.sh"]
