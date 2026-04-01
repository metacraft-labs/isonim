import { test, expect } from "@playwright/test";

test.describe("IsoNim Demo App", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
  });

  test("renders the app header", async ({ page }) => {
    await expect(page.locator("h1")).toHaveText("Task Manager");
  });

  test("shows empty state initially", async ({ page }) => {
    await expect(page.locator(".empty")).toHaveText("No tasks");
  });

  test("adds a task via form submission", async ({ page }) => {
    await page.fill('input[type="text"]', "Test task");
    await page.click('button[type="submit"]');
    await expect(page.locator(".task-list li")).toHaveCount(1);
    await expect(page.locator(".task-list li span")).toHaveText("Test task");
  });

  test("toggles task completion", async ({ page }) => {
    await page.fill('input[type="text"]', "Toggle me");
    await page.click('button[type="submit"]');
    await page.click('.task-list li input[type="checkbox"]');
    await expect(page.locator(".task-list li.completed")).toHaveCount(1);
  });

  test("removes a task", async ({ page }) => {
    await page.fill('input[type="text"]', "Remove me");
    await page.click('button[type="submit"]');
    await expect(page.locator(".task-list li")).toHaveCount(1);
    await page.click(".remove");
    await expect(page.locator(".task-list li")).toHaveCount(0);
  });

  test("filters tasks", async ({ page }) => {
    // Add two tasks
    await page.fill('input[type="text"]', "Active task");
    await page.click('button[type="submit"]');
    await page.fill('input[type="text"]', "Done task");
    await page.click('button[type="submit"]');

    // Complete second task
    const checkboxes = page.locator('.task-list li input[type="checkbox"]');
    await checkboxes.nth(1).click();

    // Filter to active
    await page.click('button:has-text("fActive")');
    await expect(page.locator(".task-list li")).toHaveCount(1);
    await expect(page.locator(".task-list li span")).toHaveText("Active task");

    // Filter to completed
    await page.click('button:has-text("fCompleted")');
    await expect(page.locator(".task-list li")).toHaveCount(1);
    await expect(page.locator(".task-list li span")).toHaveText("Done task");
  });

  test("clears completed tasks", async ({ page }) => {
    // Add and complete a task
    await page.fill('input[type="text"]', "Clear me");
    await page.click('button[type="submit"]');
    await page.click('.task-list li input[type="checkbox"]');

    // Click clear completed
    await page.click('button:has-text("Clear completed")');
    await expect(page.locator(".task-list li")).toHaveCount(0);
  });

  test("shows correct item count", async ({ page }) => {
    await page.fill('input[type="text"]', "Task 1");
    await page.click('button[type="submit"]');
    await page.fill('input[type="text"]', "Task 2");
    await page.click('button[type="submit"]');
    await expect(page.locator(".task-footer span")).toContainText(
      "2 items left",
    );

    // Complete one
    const checkboxes = page.locator('.task-list li input[type="checkbox"]');
    await checkboxes.first().click();
    await expect(page.locator(".task-footer span")).toContainText(
      "1 item left",
    );
  });
});
