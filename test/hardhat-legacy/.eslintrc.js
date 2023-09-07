module.exports = {
  env: {
    browser: true,
    es2021: true,
    jest: true,
    mocha: true,
  },
  extends: "standard-with-typescript",
  overrides: [
    {
      files: ["*.test.js", "*.spec.js"],
      rules: {
        "no-unused-expressions": "off",
      },
    },
  ],
  parserOptions: {
    ecmaVersion: "latest",
    sourceType: "module",
  },
  rules: {},
};
