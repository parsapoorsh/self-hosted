FROM ghcr.io/kiwix/kiwix-tools:latest

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /data

# ZIM files mount point; library.xml is written under /data at start
VOLUME ["/zim", "/data"]

EXPOSE 9393

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/entrypoint.sh"]

# Extra kiwix-serve flags only (port/host come from KIWIX_PORT / KIWIX_HOST)
CMD []
