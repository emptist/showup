# showup
#
# The suite is swift-testing. Its macro plugin is not loaded by this SwiftPM
# on its own, so it is passed explicitly here. Xcode wires the plugin up by
# itself, so under Xcode plain `swift test` is enough.

TEST_FLAGS = -Xswiftc -load-plugin-library \
             -Xswiftc $(shell xcrun -f swift | xargs dirname | xargs dirname)/lib/swift/host/plugins/testing/libTestingMacros.dylib

.PHONY: all build release test clean install

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean

# The installed copy only changes when a release build is reinstalled.
install: release
	install -m 0755 .build/release/showup /usr/local/bin/showup