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
                  projectsPath = "./projects";
                  assetsPath = "./assets";

                  wpVersion = "latest";

                  adminUser = "admin";
                  adminPassword = "password";
                  adminEmail = "mail@example.com";

                  db = {
                    adminUser = "admin";
                    adminPassword = "admin";

                    wordpressUser = "wordpress";
                    wordpressPassword = "wordpress";
                  };

                  pages = [
                    {
                      name = "WP Example";
                      url = "example.localhost";
                      path = "example";
                      db = "example";
                    }
                  ];

                in
                [
                  ({ pkgs, config, lib, ... }: {
                    packages = with pkgs;
                      [
                        git
                        wp-cli

                        phpactor

                        dart-sass
                        lightningcss

                        tailspin
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
                      "localhost"
                      "adminer.localhost"
                      "mailhog.localhost"
                    ] ++ builtins.foldl' (acc: page: acc ++ [ page.url ]) [ ] pages;

                    scripts.caddy-setcap.exec = ''
                      sudo setcap 'cap_net_bind_service=+ep' ${pkgs.caddy}/bin/caddy
                    '';

                    scripts.new.exec = ''
                      if [ -d ${projectsPath}/$1 ]; then
                        echo "Directory already exists"
                        exit 1
                      fi
                    
                      # Download Wordpress unless it is already downloaded
                      if [ ! -d ${assetsPath}/wordpress/${wpVersion} ]; then
                        mkdir -p ${assetsPath}/wordpress/${wpVersion}
                        ${pkgs.wp-cli}/bin/wp core download --skip-content --version=${wpVersion} --path=${assetsPath}/wordpress/${wpVersion}
                      fi

                      # Force redownload the latest version of wordpress
                      # if [ -d ${assetsPath}/wordpress/${wpVersion} && ${wpVersion} == "latest" ]; then
                      # WIP
                      # fi

                      # Copy Wordpress to new project folder
                      cp -r ${assetsPath}/wordpress/${wpVersion} ${projectsPath}/$1

                      # Setup wp-config
                      ${pkgs.wp-cli}/bin/wp config create \
                        --path=${projectsPath}/$1 \
                        --skip-check \
                        --dbhost=0.0.0.0:3306 \
                        --dbname=$1 \
                        --dbuser=${db.wordpressUser} \
                        --dbpass=${db.wordpressPassword}

                      # TODO add debug and mailtrap settings to wp-config

                      echo "New wordpress project installed to ${projectsPath}/$1"
                    '';

                    scripts.install.exec = ''
                      # Install core
                      ${pkgs.wp-cli}/bin/wp core install \
                        --path=${projectsPath}/$1 \
                        --url=$1.localhost \
                        --title=$1 \
                        --admin_user=${adminUser} \
                        --admin_password=${adminPassword} \
                        --admin_email=${adminEmail}

                      # Install mailhog plugin
                      wp plugin install https://github.com/tareq1988/mailhog-for-wp/archive/refs/heads/master.zip \
                        --path=${projectsPath}/$1 \
                        --force \
                        --activate

                      # Install all plugins from the plugins folder
                      if [ -d ${assetsPath}/plugins ]; then
                        for filename in ${assetsPath}/plugins/*.zip; do
                          wp plugin install "$filename" \
                            --path=${projectsPath}/$1 \
                            --activate
                        done
                      fi

                      # Install all themes from theme folder
                      if [ -d ${assetsPath}/themes ]; then
                        for filename in ${assetsPath}/themes/*.zip; do
                          wp theme install "$filename" \
                            --path=${projectsPath}/$1
                        done
                      fi

                      echo "WordPress installed"
                      echo ""
                      echo "https://$1.localhost/wp-admin"
                      echo "User: ${adminUser}"
                      echo "Password: ${adminPassword}"
                    '';

                    scripts.watch-css.exec = ''
                      ${pkgs.dart-sass}/bin/sass -w $1
                    '';

                    scripts.build-css.exec = ''
                      ${pkgs.dart-sass}/bin/sass --no-source-map $1
                      # WIP
                      ${pkgs.lightningcss}/bin/lightningcss --minify --bundle --targets \">= 0.25%\" input.css -o output.css
                    '';

                    services = {
                      caddy =
                        let
                          # TODO: figure out a better solution to cert names
                          certNameCount = (builtins.foldl' (acc: cert: acc + 1) 0 config.certificates) - 1;
                          certName = "localhost+${builtins.toString certNameCount}";
                          mapVirtualHosts = list: builtins.foldl'
                            (acc: page: acc // {
                              "${page.url}" = {
                                extraConfig = ''
                                  tls ${config.env.DEVENV_STATE}/mkcert/${certName}.pem ${config.env.DEVENV_STATE}/mkcert/${certName}-key.pem
                                  root * ${projectsPath}/${page.path}
                                  php_fastcgi unix/${config.languages.php.fpm.pools.web.socket}
                                  file_server
                                '';
                              };
                            })
                            { }
                            list;
                        in
                        {
                          enable = true;
                          virtualHosts = {
                            "adminer.localhost" = {
                              extraConfig = ''
                                tls ${config.env.DEVENV_STATE}/mkcert/${certName}.pem ${config.env.DEVENV_STATE}/mkcert/${certName}-key.pem
                                reverse_proxy localhost:8080
                              '';
                            };
                            "mailhog.localhost" = {
                              extraConfig = ''
                                tls ${config.env.DEVENV_STATE}/mkcert/${certName}.pem ${config.env.DEVENV_STATE}/mkcert/${certName}-key.pem
                                reverse_proxy localhost:8025
                              '';
                            };
                          } // mapVirtualHosts pages;
                        };

                      redis.enable = true;
                      adminer.enable = true;
                      mailhog.enable = true;
                      mysql = {
                        enable = true;
                        settings.mysqld = {
                          max_allowed_packet = "1024M";
                        };
                        initialDatabases = [ ] ++ builtins.foldl' (acc: page: acc ++ [{ name = "${page.db}"; }]) [ ] pages;
                        ensureUsers = [
                          {
                            name = db.adminUser;
                            password = db.adminPassword;
                            ensurePermissions = {
                              "*.*" = "ALL PRIVILEGES";
                            };
                          }
                          {
                            name = db.wordpressUser;
                            password = db.wordpressPassword;
                            ensurePermissions =
                              let
                                mapPermissions = list: builtins.foldl' (acc: page: acc // { "${page.db}.*" = "ALL PRIVILEGES"; }) { } list;
                              in
                              { } // mapPermissions pages;
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
