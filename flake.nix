{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = { self, nixpkgs, devenv, systems, ... } @ inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      packages = forEachSystem (system: {
        devenv-up = self.devShells.${system}.default.config.procfileScript;
        devenv-test = self.devShells.${system}.default.config.test;
      });

      devShells = forEachSystem
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          {
            default = devenv.lib.mkShell {
              inherit inputs pkgs;
              modules =
                let
                  projectRoot = "./projects";
                  wpVersion = "latest";

                  projectName = "proj3dzonen";
                  projectUrl = "${projectName}.localhost";
                  # WIP: multiple sites support


                  pages = [
                    {
                      name = "3Dzonen";
                      url = "proj3dzonen.localhost";
                      path = "proj3dzonen";
                      db = "proj3dzonen";
                    }
                    {
                      name = "Naturmissionen";
                      url = "naturmissionen.localhost";
                      path = "naturmissionen";
                      db = "naturmissionen";
                    }
                  ];

                in
                [
                  ({ pkgs, config, ... }: {
                    packages = with pkgs;
                      [
                        git
                        wp-cli
                        phpactor
                        dart-sass
                      ];

                    languages.javascript.enable = true;

                    languages.php.enable = true;
                    languages.php.package = pkgs.php82.buildEnv {
                      extensions = { all, enabled }: with all; enabled ++ [ redis pdo_mysql xdebug ];
                      extraConfig = ''
                        memory_limit = -1
                        xdebug.mode = debug
                        xdebug.start_with_request = yes
                        xdebug.idekey = vscode
                        xdebug.log_level = 0
                        max_execution_time = 0
                      '';
                    };

                    languages.php.fpm.pools.web = {
                      settings = {
                        "clear_env" = "no";
                        "pm" = "dynamic";
                        "pm.max_children" = 10;
                        "pm.start_servers" = 2;
                        "pm.min_spare_servers" = 1;
                        "pm.max_spare_servers" = 10;
                      };
                    };

                    certificates = [
                      "${projectUrl}"
                      "naturmissionen.localhost"
                    ];


                    scripts.build-css.exec = ''
                    '';

                    scripts.caddy-setcap.exec = ''
                      sudo setcap 'cap_net_bind_service=+ep' ${pkgs.caddy}/bin/caddy
                    '';

                    scripts.setup-page.exec = ''
                      echo "TODO"
                      wp core download --skip-content --version=${wpVersion} --path=./assets/wordpress
                    '';

                    services = {
                      caddy = {
                        enable = true;
                        virtualHosts = {
                          "naturmissionen.localhost" = {
                            extraConfig = ''
                              tls ${config.env.DEVENV_STATE}/mkcert/naturmissionen.localhost.pem ${config.env.DEVENV_STATE}/mkcert/naturmissionen.localhost-key.pem
                              root * ${projectRoot}/reepark-naturmissionen
                              php_fastcgi unix/${config.languages.php.fpm.pools.web.socket}
                              file_server
                            '';
                          };
                          "${projectName}.localhost" = {
                            extraConfig = ''
                              tls ${config.env.DEVENV_STATE}/mkcert/${projectUrl}.pem ${config.env.DEVENV_STATE}/mkcert/${projectUrl}-key.pem
                              root * ${projectRoot}/${projectName}
                              php_fastcgi unix/${config.languages.php.fpm.pools.web.socket}
                              file_server
                            '';
                          };
                        };
                      };

                      redis.enable = true;
                      adminer.enable = true;
                      mailhog.enable = true;
                      mysql = {
                        enable = true;
                        settings.mysqld = {
                          max_allowed_packet = "1024M";
                        };
                        initialDatabases = [{ name = "${projectName}"; } { name = "naturmissionen"; }];
                        ensureUsers = [
                          {
                            name = "admin";
                            password = "admin";
                            ensurePermissions = {
                              "*.*" = "ALL PRIVILEGES";
                            };
                          }
                          {
                            name = "wordpress";
                            password = "wordpress";
                            ensurePermissions = {
                              "naturmissionen.*" = "ALL PRIVILEGES";
                              "${projectName}.*" = "ALL PRIVILEGES";
                            };
                          }
                        ];
                      };
                    };
                  })
                ];
            };
          });
    };
}
