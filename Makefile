# showup
#
# The suite is swift-testing. Its macro plugin is not loaded by this SwiftPM
# on its own, so it is passed explicitly here. Xcode wires the plugin up by
# itself, so under Xcode plain `swift test` is enough.

TEST_FLAGS = -Xswiftc -load-plugin-library \
             -Xswiftc $(shell xcrun -f swift | xargs dirname | xargs dirname)/lib/swift/host/plugins/testing/libTestingMacros.dylib

# The line every run logs about itself. The sha answers "which binary made
# this log", which is the question every post-mortem here starts with.
SHA  = $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE = $(shell LC_ALL=C date '+%Y-%m-%d %H:%M %z')

stamp_file = $(1)/showup.stamp
define write_stamp
	  printf 'build $(SHA) $(DATE)\n' > $(call stamp_file,$(1))
endef

.PHONY: all build release test clean install

all: build

build:
	swift build
	$(call write_stamp,.build/debug)

release:
	swift build -c release
	$(call write_stamp,.build/release)

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean

# The installed copy only changes when a release build is reinstalled, and the
# stamp goes with it: a stamped log about a stampless binary is still a guess.
install: release
	install -m 0755 .build/release/showup /usr/local/bin/showup
	install -m 0644 .build/release/showup.stamp /usr/local/bin/showup.stamp