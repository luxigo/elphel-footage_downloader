PREFIX=/usr/local

all:

install:
	cp -rv bin ${PREFIX}/
	cp -rv etc /
	$(MAKE) -C sshall install PREFIX=${PREFIX}

