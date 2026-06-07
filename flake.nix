{
  description = "Attic binary cache server for osmzhlab.uni-muenster.de";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    packages.x86_64-linux = {
      attic-server = pkgs.attic-server;
      attic-client = pkgs.attic-client;
    };
  };
}
