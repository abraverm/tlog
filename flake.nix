{
  description = "tlog: terminal I/O recording and playback tool";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nix-filter.url = "github:numtide/nix-filter";

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nix-filter,
  }: let
    forAllSystems = flake-utils.lib.eachDefaultSystem;
  in (forAllSystems (
    system: let
      pkgs = import nixpkgs {inherit system;};
      filter = nix-filter.lib;
    in {
      packages.default = pkgs.stdenv.mkDerivation {
        pname = "tlog";
        version = "git";
        src = filter {
          root = ./.;
          exclude = [
            "flake.nix"
            "flake.lock"
          ];
        };
        nativeBuildInputs = with pkgs; [
          autoconf
          automake
          libtool
          m4
          pkg-config
          makeWrapper
        ];
        buildInputs = with pkgs; [
          gcc
          json_c
          curl
          systemd
          libutempter
        ];
        configurePhase = ''
          autoreconf -i -f
          ./configure --prefix=$out --sysconfdir=$out/etc --localstatedir=/var
        '';
        buildPhase = "make";
        installPhase = "make install";
        outputs = ["out" "man"];
        postInstall = ''
          if [ -d $out/share/man ]; then
            mkdir -p $man/share
            mv $out/share/man $man/share/
          fi
        '';
      };
      checks.tlog = pkgs.nixosTest {
        name = "tlog";
        nodes.machine = {config, ...}: {
          imports = [self.nixosModules.${system}.tlog];
          services.tlog = {
            enable = true;
            recorders.fileRecorder = {
              shell = "${pkgs.bash}/bin/bash";
              log.input = true;
              writer = "file";
              file.path = "/tmp/example-session.log";
              limit = {
                # rate = 1000000;
                # burst = 60;
                action = "pass"; # default and effectively disabling rate-limiting
              };
            };
            recorders.journalRecorder = {
              shell = "${pkgs.bash}/bin/bash";
              log.input = true;
              writer = "journal";
              limit = {
                # rate = 1000000;
                # burst = 60;
                action = "pass"; # default and effectively disabling rate-limiting
              };
            };
          };
          users.users.userA = {
            extraGroups = ["tlog"];
            isNormalUser = true;
            shell = config.services.tlog.path.fileRecorder;
          };
          users.users.userB = {
            extraGroups = ["tlog"];
            isNormalUser = true;
            shell = config.services.tlog.path.journalRecorder;
          };
        };
        testScript = ''
          machine.wait_for_unit("default.target")
          machine.execute("su - userB -c 'echo hello world > /tmp/test1'", check_return=False, check_output=False, timeout=5)
          machine.succeed("grep 'hello world' /tmp/test1")
          machine.succeed("su - userB -c 'echo hello world'")
          machine.succeed("journalctl -t tlog-rec-session --no-pager | grep 'hello world'")
          machine.succeed("su - userA -c 'echo hello world'")
          machine.succeed("grep 'hello world' /tmp/example-session.log")
        '';
      };
      nixosModules.tlog = {
        config,
        lib,
        pkgs,
        ...
      }:
        with lib; {
          options.services.tlog = {
            enable = mkEnableOption "Tlog terminal session recording/playback";
            package = mkOption {
              type = types.package;
              default = self.packages.${system}.default;
              description = "Tlog package to use.";
            };
            recorders = mkOption {
              type = types.attrsOf types.attrs;
              default = {};
              description = "Recorder definitions for tlog-rec-session wrappers.";
            };
            path = mkOption {
              type = types.attrs;
              readOnly = true;
              description = "Each recorder's wrapper path.";
            };
          };
          config = mkIf config.services.tlog.enable {
            environment.systemPackages = [config.services.tlog.package];
            users.groups.tlog = {};
            systemd.tmpfiles.rules = [
              "d /run/tlog 0770 - tlog -"
            ];
            services.tlog.path = lib.genAttrs (builtins.attrNames config.services.tlog.recorders) (
              name: "${pkgs.writeShellScriptBin "tlog-rec-session" ''
                export TLOG_REC_SESSION_CONF_TEXT='${builtins.toJSON config.services.tlog.recorders.${name}}'
                ${config.services.tlog.package}/bin/tlog-rec-session "$@"
              ''}/bin/tlog-rec-session"
            );
          };
        };
    }
  ));
}
