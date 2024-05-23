function(
    target,
    pkg_org,
) std.manifestYamlDoc(
    {
        name: "Update packages",
        on: {
            repository_dispatch: {
                types: [
                    "new_package_release"
                ],
            },
            workflow_dispatch: {},
        },
        permissions: {},
        concurrency: {
            group: "${{ github.workflow }}-${{ github.ref }}",
            "cancel-in-progress": true,
        },
        jobs: {
            update: {
                "runs-on": "ubuntu-latest",
                permissions: {
                    pages: "write",         // for pages
                    "id-token": "write",    // for pages
                    contents: "write",      // for git push
                },
                steps: [
                    {
                        name: "Checkout rsdk",
                        uses: "actions/checkout@v4",
                        with: {
                            repository: "RadxaOS-SDK/rsdk"
                        },
                    },
                    {
                        name: "Checkout current repo",
                        uses: "actions/checkout@v4",
                        with: {
                            path: ".infra-repo"
                        },
                    },
                    {
                        name: "Build apt archive",
                        id: "build",
                        shell: "bash",
                        env: {
                            GH_TOKEN: "${{ secrets.GITHUB_TOKEN }}",
                        },
                        run: |||
                            # ubuntu-latest is currently ubuntu-22.04, which provides aptly 1.4.0
                            # Only 1.5.0 supports Ubuntu's zstd compressed packages:
                            #   https://github.com/aptly-dev/aptly/pull/1050
                            # ubuntu-24.04 provides 1.5.0, but will not be available till August:
                            #   https://github.com/actions/runner-images/issues/9691#issuecomment-2063926929
                            # Install aptly from upstream archive for now.
                            sudo tee /etc/apt/sources.list.d/10-aptly.list <<< "deb http://repo.aptly.info/ squeeze main"
                            sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys EE727D4449467F0E

                            sudo apt-get update
                            sudo apt-get install -y aptly pandoc
                            git config --global user.name 'github-actions[bot]'
                            git config --global user.email '41898282+github-actions[bot]@users.noreply.github.com'

                            cat << EOF | gpg --import
                            ${{ secrets.GPG_KEY }}
                            EOF
                            cat << EOF | gpg --import
                            ${{ secrets.RADXA_APT_KEY_2024 }}
                            EOF

                            suites=(
                                "%(target)s"
                                "amlogic-%(target)s"
                                "rockchip-%(target)s"
                            )

                            pushd .infra-repo
                            if [[ "${{ github.repository }}" != *-test ]] && \
                                wget "https://raw.githubusercontent.com/${{ github.repository }}-test/main/pkgs.lock" -O pkgs.lock.new; then
                                mv pkgs.lock.new pkgs.lock
                                git add pkgs.lock
                            fi

                            ../src/bin/rsdk infra-pkg-snapshot
                            ../src/bin/rsdk infra-pkg-download "${suites[@]}"
                            ../src/bin/rsdk infra-repo-sync "${suites[@]}"
                            export RSDK_REPO_ORIGIN="$(../src/bin/rsdk config infra.repository.origin)"
                            git add pkgs.json

                            pushd "$HOME/.aptly/public/$RSDK_REPO_ORIGIN/"
                                cp "$OLDPWD/pkgs.json" ./
                                pandoc --from gfm --to html --standalone "$OLDPWD/README.md" --output index.html
                                find . > files.list
                                echo "pages=$(realpath .)" >> $GITHUB_OUTPUT
                            popd

                            if [[ -n "$(git status --porcelain)" ]]; then
                                git commit -m "chore: update package snapshot"
                            fi
                            popd
                        ||| % {target: target},
                    },
                    {
                        name: "Setup GitHub Pages",
                        uses: "actions/configure-pages@v5",
                    },
                    {
                        name: "Upload artifact",
                        uses: "actions/upload-pages-artifact@v3",
                        with: {
                            path: "${{ steps.build.outputs.pages }}"
                        },
                    },
                    {
                        name: "Deploy to GitHub Pages",
                        id: "deploy",
                        uses: "actions/deploy-pages@v4",
                        "if": "github.event_name != 'pull_request'",
                    },
                    {
                        name: "Commit package snapshot",
                        "if": "steps.deploy.outcome == 'success'",
                        shell: "bash",
                        run: |||
                            pushd .infra-repo
                            git push
                            popd
                        |||,
                    },
                ],
            },
        },
    },
    quote_keys=false,
)
