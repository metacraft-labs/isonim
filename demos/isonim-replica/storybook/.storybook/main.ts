import type { StorybookConfig } from "@storybook/html-webpack5";

const config: StorybookConfig = {
  stories: ["../stories/**/*.stories.@(js|ts)"],
  addons: ["@storybook/addon-essentials", "@storybook/addon-interactions"],
  framework: {
    name: "@storybook/html-webpack5",
    options: {},
  },
  staticDirs: [
    // Serve the compiled IsoNim JS bundle from storybook/dist/
    // so stories can load it at ./dist/components.js
    { from: "../dist", to: "/dist" },
  ],
};

export default config;
