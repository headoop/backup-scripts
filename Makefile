# PREFIX is environment variable, but if it is not set, then set default value
ifeq ($(PREFIX),)
    PREFIX := /usr/local
endif

INSTALL = install
DESTDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share
UNITDIR = /etc/systemd/system
FILES = backup-daily.sh backup-weekly.sh backup-encrypted-usb.sh pacman-list-changed-files.sh systemd-failure-mail.sh
SHAREFILES = rsync-excludes.txt
UNITS = backup-daily.service backup-daily.timer backup-weekly.service backup-weekly.timer failure-mail@.service

.PHONY: all install uninstall

all:
	@echo "Run 'make install' to install the scripts."

install:
	$(INSTALL) -v --compare -m 755 $(FILES) $(DESTDIR)
	$(INSTALL) -v --compare -m 644 $(SHAREFILES) $(SHAREDIR)
	$(INSTALL) -v --compare -m 644 $(UNITS) $(UNITDIR)
	@echo ""
	@echo "To enable the systemd timers, run:"
	@echo "  systemctl daemon-reload"
	@echo "  systemctl enable --now backup-daily.timer"
	@echo "  systemctl enable --now backup-weekly.timer"

uninstall:
	for file in $(FILES); do rm -f $(DESTDIR)/$$file; done
	for file in $(SHAREFILES); do rm -f $(SHAREDIR)/$$file; done
	for unit in $(UNITS); do rm -f $(UNITDIR)/$$unit; done
	@echo ""
	@echo "To clean up the systemd state, run:"
	@echo "  systemctl disable --now backup-daily.timer"
	@echo "  systemctl disable --now backup-weekly.timer"
	@echo "  systemctl daemon-reload"
