import type { StorybookConfig } from "@storybook/html-webpack5";

const config: StorybookConfig = {
  stories: ["../stories/**/*.stories.@(js|ts)"],
  addons: ["@storybook/addon-essentials"],
  framework: {
    name: "@storybook/html-webpack5",
    options: {},
  },
};

export default config;
