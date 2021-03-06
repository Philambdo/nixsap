{ config, pkgs, lib, ... }:

let
  inherit (builtins)
    dirOf ;
  inherit (lib)
    concatMapStringsSep concatStringsSep filter hasPrefix isString
    mapAttrsToList mkEnableOption mkIf mkOption optionalString types ;
  inherit (types)
    attrsOf bool either enum int listOf nullOr path str submodule ;

  cfg = config.nixsap.apps.icinga2;
  rundir = "/run/icinga2";
  pidFile = "${rundir}/icinga2.pid";

  mutableDir = "mutable.d";
  mutableTmpDir = "mutable.tmp.d";
  mutablePath = "${cfg.stateDir}/etc/icinga2/${mutableDir}";
  mutableTmpPath = "${cfg.stateDir}/etc/icinga2/${mutableTmpDir}";
  mutableRestart = "${mutablePath}/restart";

  icingaMutableUpdate =
    let
      job = n: j: pkgs.writeBashScript "icinga-mutable-${n}" ''
        set -euo pipefail
        f='${mutableTmpPath}/${n}.conf'
        ${j} > "$f.tmp"
        mv -f "$f.tmp" "$f"
      '';
    in pkgs.writeBashScript "icinga-mutable-update" ''
      set -euo pipefail

      rm -rf ${mutableTmpPath}
      mkdir -p ${mutableTmpPath}

      HOME=${rundir}
      PARALLEL_SHELL=${pkgs.bash}/bin/bash
      export PARALLEL_SHELL

      # shellcheck disable=SC2016
      ${pkgs.parallel}/bin/parallel \
        --delay 2 \
        --halt-on-error 0 \
        --line-buffer \
        --no-notice \
        --no-run-if-empty \
        --rpl '{name} s:^.*-icinga-mutable-(.+)$:$1:' \
        --timeout 120 \
        --tagstr '* {name}:' \
        ::: \
        ${concatStringsSep " " (
          mapAttrsToList job cfg.mutable.conf
        )} \
        || exit 1 # WARNING

      old=$(${pkgs.nix}/bin/nix-hash --type sha1 '${mutablePath}')
      new=$(${pkgs.nix}/bin/nix-hash --type sha1 '${mutableTmpPath}')
      if [ "$old" != "$new" ]; then
        ${pkgs.gnused}/bin/sed 's,${mutablePath},${mutableTmpPath},' \
          ${icingaConf} > \
          ${cfg.stateDir}/etc/icinga2/icinga2.tmp.conf
        if ! ${pkgs.icinga2}/bin/icinga2 daemon -C -x critical -c ${cfg.stateDir}/etc/icinga2/icinga2.tmp.conf; then
          exit 2 # CRITICAL
        fi
        rm -f ${cfg.stateDir}/etc/icinga2/icinga2.tmp.conf
        rm -rf ${mutablePath}.bak
        mv -f ${mutablePath} ${mutablePath}.bak
        mv -f ${mutableTmpPath} ${mutablePath}
        rm -rf ${mutablePath}.bak
        if [ -f ${pidFile} ]; then
          pid=$(cat ${pidFile})
          if ${pkgs.coreutils}/bin/kill -0 "$pid"; then
            touch ${mutableRestart}
            ${pkgs.coreutils}/bin/kill -HUP "$pid"
            echo "Restart: $old -> $new"
          fi
        fi
      else
        echo "No changes: $old"
      fi
    '';

  icingaMutableCheckCommand = pkgs.writeText "icinga-${cfg.mutable.checkCommand}.conf" ''
    object CheckCommand "${cfg.mutable.checkCommand}" {
      import "plugin-check-command"
      command = [ "${icingaMutableUpdate}" ]
    }
  '';

  idoPasswordFile = "${rundir}/ido-password.conf";

  idoConf = with cfg.ido;
    let
      obj = {
        mysql = "IdoMysqlConnection";
        pgsql = "IdoPgsqlConnection";
      };
    in pkgs.writeText "icinga-ido.conf" ''
      library "db_ido_${type}"

      include "${idoPasswordFile}"

      # TODO: maybe more options including mysql/pgsql specific
      object ${obj.${type}} "ido-database" {
        database = "${database}"
        host     = "${host}"
        port     = ${toString port}
        password = IdoDbPassword # XXX read from a secret file in runtime
        user     = "${user}"
      }
    '';

  icingaConf = pkgs.writeText "icinga2.conf"
    ''
      const PluginDir = "${pkgs.monitoringPlugins}/libexec"

      include <itl>
      include <plugins>

      object Endpoint NodeName {
        host = NodeName
      }
      object Zone NodeName {
        endpoints = [ NodeName ]
      }

      include "${cfg.stateDir}/etc/icinga2/features-enabled/*.conf"
      include "${cfg.stateDir}/etc/icinga2/conf.d/*.conf"
      include_recursive "${cfg.stateDir}/etc/icinga2/repository.d"
      include "${mutablePath}/*.conf"

      ${optionalString (cfg.ido.type != null) ''
        include "${idoConf}"
      ''}

      ${concatMapStringsSep "\n" (f:
          if hasPrefix "/" f
          then ''include "${f}"''
          else ''include "${pkgs.writeText "icinga2.inc.conf" f}"''
        ) cfg.configFiles}
    '';

  console = pkgs.writeBashScriptBin "icinga2console" ''
    if [ -z "$ICINGA2_API_USERNAME" ] && [ -r ${cfg.stateDir}/etc/icinga2/conf.d/api-users.conf ]; then
      pwd=$(${pkgs.gnused}/bin/sed -rn 's,.*password\s*=\s*"(.+)".*,\1,p' ${cfg.stateDir}/etc/icinga2/conf.d/api-users.conf)
      export ICINGA2_API_USERNAME=root
      export ICINGA2_API_PASSWORD="$pwd"
    fi
    exec ${pkgs.icinga2}/bin/icinga2 console --connect 'https://localhost/' "$@"
  '';

  configureDB = with cfg.ido; {
    mysql =
      let
        secret = "${cfg.stateDir}/.my.cnf";
        mycnf = pkgs.writeText "icinga2-my.cnf" ''
          [client]
          host = ${host}
          port = ${toString port}
          user = ${user}
          database = ${database}
          ${optionalString (passfile != null) "!include ${secret}"}
        '';
        mysql = pkgs.writeBashScript "icinga2-mysql" ''
          exec "${pkgs.mysql.client}/bin/mysql" \
            --defaults-file='${mycnf}' "$@"
        '';
      in pkgs.writeBashScript "icinga2-mysql.sh" ''
        set -euo pipefail
        ${optionalString (passfile != null) ''
          rm -f '${secret}'
          printf '[client]\npassword=' > '${secret}'
          cat '${passfile}' >> '${secret}'
        ''}
        while ! ${mysql} -e ';'; do
          sleep 5s
        done
        tt=$(${mysql} -N -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = "${database}"')
        if [ "$tt" -eq 0 ]; then
          ${mysql} < '${pkgs.icinga2}/share/icinga2-ido-mysql/schema/mysql.sql'
        fi
      '';

      pgsql =
        let
          pgpass = "${cfg.stateDir}/.pgpass";
          psql = pkgs.writeBashScript "icinga2psql" ''
            exec ${pkgs.postgresql}/bin/psql \
              -v ON_ERROR_STOP=1 \
              --no-password \
              --host='${host}' \
              --port=${toString port} \
              --dbname='${database}' \
              --username='${user}' \
              "$@"
          '';
        in pkgs.writeBashScript "icinga2-pgsql.sh" ''
          set -euo pipefail
          ${optionalString (passfile != null) ''
            rm -f '${pgpass}'
            printf '*:*:*:*:' > '${pgpass}'
            cat '${passfile}' >> '${pgpass}'
            chmod 0600 '${pgpass}'
            export PGPASSFILE='${pgpass}'
          ''}

          while ! ${psql} -c ';'; do
            sleep 5s
          done

          tt=$(${psql} --tuples-only -c "SELECT count(*) FROM pg_class WHERE relname='icinga_dbversion'")
          if [ "$tt" -eq 0 ]; then
            ${psql} --single-transaction -f '${pkgs.icinga2}/share/icinga2-ido-pgsql/schema/pgsql.sql'
          fi
        '';
  };

  preStart = ''
    umask 0077
    mkdir -p \
      ${cfg.stateDir}/cache/icinga2 \
      ${cfg.stateDir}/lib/icinga2/api/log \
      ${cfg.stateDir}/lib/icinga2/api/repository \
      ${cfg.stateDir}/lib/icinga2/api/zones \
      ${cfg.stateDir}/log/icinga2/compat/archives \
      ${cfg.stateDir}/log/icinga2/crash \
      ${cfg.stateDir}/spool/icinga2/perfdata \
      ${cfg.stateDir}/spool/icinga2/tmp

    ${pkgs.findutils}/bin/find \
      ${cfg.stateDir}/etc/icinga2 \
      -mindepth 1 -maxdepth 1 \
      -not -name ${mutableDir} \
      -not -name pki \
      -not -name repository.d \
      -exec rm -rf '{}' \; || true

    mkdir -p \
      ${cfg.stateDir}/etc/icinga2/conf.d \
      ${mutablePath} \
      ${cfg.stateDir}/etc/icinga2/repository.d \
      ${cfg.stateDir}/etc/icinga2/features-enabled
    ln -sf ${pkgs.icinga2}${cfg.stateDir}/etc/icinga2/features-available \
           ${cfg.stateDir}/etc/icinga2/features-available
    ln -sf ${pkgs.icinga2}${cfg.stateDir}/etc/icinga2/scripts \
           ${cfg.stateDir}/etc/icinga2/scripts

    # XXX Can't include in the main file due to infinite recursion
    ln -sf ${icingaMutableCheckCommand} \
      ${cfg.stateDir}/etc/icinga2/conf.d/${cfg.mutable.checkCommand}.conf

    rm -rf ${rundir}
    mkdir --mode=0755 -p ${rundir}
    mkdir --mode=2710 -p ${dirOf cfg.commandPipe}
    mkdir --mode=2710 -p ${dirOf cfg.livestatusSocket}
    chown -R ${cfg.user}:${cfg.user} ${rundir}
    chown -Rc ${cfg.user}:${cfg.user} ${cfg.stateDir}
    chmod -R u=rwX,g=rX,o= ${cfg.stateDir}
    chown ${cfg.user}:${cfg.commandGroup} ${dirOf cfg.commandPipe}
    chown ${cfg.user}:${cfg.commandGroup} ${dirOf cfg.livestatusSocket}
  '';

  start = pkgs.writeBashScriptBin "icinga2" ''
    set -euo pipefail
    umask 0077

    # XXX Requires root for no fucking reason, see https://github.com/Icinga/icinga2/issues/4947
    ${pkgs.fakeroot}/bin/fakeroot ${pkgs.icinga2}/bin/icinga2 api setup
    ${pkgs.fakeroot}/bin/fakeroot ${pkgs.icinga2}/bin/icinga2 feature enable checker
    ${pkgs.fakeroot}/bin/fakeroot ${pkgs.icinga2}/bin/icinga2 feature enable command
    ${pkgs.fakeroot}/bin/fakeroot ${pkgs.icinga2}/bin/icinga2 feature enable livestatus

    ${optionalString cfg.notifications ''
      ${pkgs.fakeroot}/bin/fakeroot ${pkgs.icinga2}/bin/icinga2 feature enable notification
    ''}

    ${optionalString (cfg.ido.type != null) ''
      ${if (cfg.ido.passfile != null)
        then "pwd=$(cat '${cfg.ido.passfile}'"
        else "pwd=''"}
      printf 'const IdoDbPassword = "%s"\n' "$pwd" > '${idoPasswordFile}'
    ''}

    printf 'const TicketSalt = "%s"\n' "$(${pkgs.pwgen}/bin/pwgen -1 -s 23)" \
      > ${cfg.stateDir}/etc/icinga2/conf.d/ticketsalt.conf

    if [ -e ${mutableRestart} ]; then
      rm ${mutableRestart}
    else
      ${icingaMutableUpdate} || true
      if ! ${pkgs.icinga2}/bin/icinga2 daemon -C -x critical -c ${icingaConf}; then
        rm -rf ${mutablePath}
        mkdir -p ${mutablePath}
      fi
    fi

    exec ${pkgs.icinga2}/bin/icinga2 daemon -x ${cfg.logLevel} -c ${icingaConf}
  '';

in {

  options.nixsap = {
    apps.icinga2 = {
      enable = mkEnableOption "icinga2";

      logLevel = mkOption {
        description = "Icinga2 daemon log level";
        type = enum [ "debug" "notice" "information" "warning" "critical" ];
        default = "information";
      };

      notifications = mkOption {
        description = "Enable notifications";
        type = bool;
        default = false;
      };

      ido = mkOption {
        description = ''
          Configure Icinga Data Output.  This includes automatic
          database bootstrap (importing SQL shcema).  You may
          opt into manual configuration with regular config files
          (`configFiles`) for the maximum flexibility.
        '';
        # TODO: may add more options, backend-specific options
        # depending on the backend type.
        type = submodule {
          options = {
            type = mkOption {
              description = "IDO backend type";
              type = nullOr (enum ["mysql" "pgsql"]);
              default = null;
            };
            host = mkOption {
              description = "Database host. May be a directory with the UNIX-socket for pgsql";
              type = str;
            };
            port = mkOption {
              description = "Database port";
              type = int;
            };
            database = mkOption {
              description = "Database name";
              type = str;
              default = "icinga";
            };
            user = mkOption {
              description = "Database login";
              type = str;
              default = cfg.user;
            };
            passfile = mkOption {
              description = "A file with the password (secret)";
              type = nullOr path;
              default = null;
            };
          };
        };
      };

      configFiles = mkOption {
        description = ''
          Configuration files or inline text
          to be included in the main file'';
        type = listOf (either str path);
      };

      mutable.conf = mkOption {
        description = ''
          A set of executables to write mutable config files.
        '';
        type = attrsOf path;
        default = {};
      };
      mutable.checkCommand = mkOption {
        description = ''
          Name of the mutable check command. You may need to alter this
          only in an unlikely case of conflict with your custom commands.
          Mutable files are updated every time icinga2 restart. If you want
          better control and observability on this, create a service with
          this check command. If exists, this service will make icinga2
          restart when mutable files change (and pass syntax check) via
          sending the HUP signal to the main icinga2 process.
        '';
        type = str;
        default = "mutable-conf-refresh";
      };

      # these are hard-coded into icinga2 package:
      user = mkOption {
        type = types.str;
        description = "User to run as";
        default = "icinga";
        readOnly = true;
      };

      commandGroup = mkOption {
        type = types.str;
        description = "Dedicated command group for command pipe and livestatus";
        default = "icingacmd";
        readOnly = true;
      };

      stateDir = mkOption {
        type = types.path;
        description = "Icinga2 logs, state, config files";
        default = "/icinga2";
        readOnly = true;
      };

      commandPipe = mkOption {
        type = types.path;
        description = "Icinga2 command pipe";
        default = "${rundir}/cmd/icinga2.cmd";
        readOnly = true;
      };

      livestatusSocket = mkOption {
        type = types.path;
        description = "Icinga2 Livestatus socket";
        default = "${rundir}/cmd/livestatus";
        readOnly = true;
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ console ];
    nixsap.apps.icinga2.configFiles = [
      "${pkgs.icinga2}/icinga2/etc/icinga2/conf.d/app.conf"
      "${pkgs.icinga2}/icinga2/etc/icinga2/conf.d/commands.conf"
      "${pkgs.icinga2}/icinga2/etc/icinga2/conf.d/notifications.conf"
      "${pkgs.icinga2}/icinga2/etc/icinga2/conf.d/templates.conf"
      "${pkgs.icinga2}/icinga2/etc/icinga2/conf.d/timeperiods.conf"
    ];
    nixsap.system.users.daemons = [ cfg.user ];
    nixsap.system.groups = [ cfg.commandGroup ];
    nixsap.deployment.keyrings.${cfg.user} = filter (hasPrefix config.nixsap.deployment.keyStore) cfg.configFiles;
    users.users.${cfg.user}.extraGroups = [ "proc" ];

    systemd.services.icinga2 = {
      description = "Icinga2 daemon";
      after = [ "local-fs.target" "keys.target" "network.target" ];
      wants = [ "keys.target" ];
      wantedBy = [ "multi-user.target" ];
      inherit preStart;
      serviceConfig = {
        ExecStart = "${start}/bin/icinga2";
        KillMode = "mixed";
        PermissionsStartOnly = true;
        Restart = "always";
        TimeoutSec = 600;
        User = cfg.user;
      };
    };

    systemd.services.icinga2db = mkIf (cfg.ido.type != null) {
      description = "Icinga2 databases configurator";
      after = [ "icinga2.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ console ];
      serviceConfig = {
        ExecStart = configureDB.${cfg.ido.type};
        User = cfg.user;
        RemainAfterExit = true;
        Restart = "on-failure";
      };
    };
  };
}

