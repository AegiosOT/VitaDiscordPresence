class Vitapresence < Formula
  desc "Show the PS Vita game you're playing on Discord"
  homepage "https://github.com/AegiosOT/VitaDiscordPresence"
  license "GPL-2.0-only"
  head "https://github.com/AegiosOT/VitaDiscordPresence.git"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :ventura

  def install
    build = buildpath/"build"
    ENV["VITAPRESENCE_BUILD_DIR"] = build.to_s
    # SwiftUI's macros are in the Xcode toolchain. The Command Line Tools compiler cannot build the app.
    xcode = "/Applications/Xcode.app/Contents/Developer"
    ENV["DEVELOPER_DIR"] = xcode if File.directory?(xcode)

    arch = Hardware::CPU.arm? ? "arm64" : "x86_64"
    cd "mac" do
      system "scripts/build-app.sh", "--arch", arch
      system "make", "cli", "BUILD_DIR=#{build}"
    end

    cli = Dir["#{build}/swiftpm/**/vitapresence-cli"].find do |path|
      File.file?(path) && File.executable?(path) && path.exclude?(".dSYM")
    end
    odie "vitapresence-cli was not built" if cli.nil?
    bin.install cli

    prefix.install build/"VitaPresence.app"
    (bin/"vitapresence").write <<~SH
      #!/bin/bash
      open "#{opt_prefix}/VitaPresence.app"
    SH
    chmod 0755, bin/"vitapresence"
  end

  def caveats
    <<~EOS
      VitaPresence is a menu-bar app. Start it with:

        vitapresence

      vitapresence-cli is the command-line client.
      macOS will ask to allow the local network so the app can find the Vita.
    EOS
  end

  test do
    assert_match(/^vitapresence-cli \d+\.\d+\.\d+$/, shell_output("#{bin}/vitapresence-cli --version").strip)
    assert_path_exists prefix/"VitaPresence.app/Contents/MacOS/VitaPresence"
  end
end
