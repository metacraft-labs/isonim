// webpack.config.js — minimal Webpack 5 setup that hosts an
// isonim component via nim-loader.
//
// HMR is enabled by setting `devServer.hot: true` (the default for
// modern webpack-dev-server) and importing the loaded module as a
// side effect from a self-accepting entry. The nim-loader appends
// `module.hot.accept()` to every compiled .nim module so the
// HMR runtime stops bubbling at the isonim boundary.

const path = require("path");
const HtmlWebpackPlugin = require("html-webpack-plugin");

const ISONIM_ROOT = path.resolve(__dirname, "..", "..", "src");
const NIM_EVERYWHERE_ROOT = path.resolve(
  __dirname,
  "..",
  "..",
  "..",
  "nim-everywhere",
  "src",
);

module.exports = {
  mode: "development",
  entry: "./src/main.js",
  output: {
    path: path.resolve(__dirname, "dist"),
    filename: "bundle.js",
    clean: true,
  },
  module: {
    rules: [
      {
        test: /\.nim$/,
        use: [
          {
            loader: path.resolve(__dirname, "nim-loader.cjs"),
            options: {
              searchPaths: [ISONIM_ROOT, NIM_EVERYWHERE_ROOT],
            },
          },
        ],
      },
    ],
  },
  resolve: {
    // .nim isn't a JS extension; the rule above handles import
    // resolution via the loader, but we still need webpack to
    // accept the extension when resolving paths.
    extensions: [".js", ".nim"],
  },
  plugins: [
    new HtmlWebpackPlugin({
      template: path.resolve(__dirname, "src", "index.html"),
    }),
  ],
  devServer: {
    port: 5181,
    hot: true,
    // Pin the WS URL so the spec doesn't have to guess.
    client: { webSocketURL: "ws://localhost:5181/ws" },
  },
};
