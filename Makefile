VERSION=0.1.3
PREFIX?=/usr
BINDIR?=$(PREFIX)/bin
MANDIR?=$(PREFIX)/share/man

SVCDIR?=/etc/sv
.DEFAULT_GOAL=all

crore:
	hare build

crore.1: crore.1.scd
	scdoc < $< > $@

all: crore crore.1

clean:
	rm crore crore.1

install: all
	mkdir -p $(DESTDIR)$(BINDIR) $(DESTDIR)$(MANDIR)/man1
	install -m755 crore $(DESTDIR)$(BINDIR)/crore
	install -m644 crore.1 $(DESTDIR)$(MANDIR)/man1/crore.1

install-runit: install
	mkdir -p $(DESTDIR)$(SVCDIR)/crore
	mkdir -p $(DESTDIR)$(SVCDIR)/crore/log
	install -m755 sv/runit/crore/run $(DESTDIR)$(SVCDIR)/crore
	install -m644 sv/runit/crore/config $(DESTDIR)$(SVCDIR)/crore
	install -m644 sv/runit/crore/tab $(DESTDIR)$(SVCDIR)/crore
	install -m755 sv/runit/crore/log/run $(DESTDIR)$(SVCDIR)/crore/log

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/crore
	rm -f $(DESTDIR)$(MANDIR)/man1/crore.1
	rm -rf $(DESTDIR)$(SVCDIR)/crore

check:
	hare test
