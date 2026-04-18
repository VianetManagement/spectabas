defmodule Spectabas.GoalsTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.Goals
  alias Spectabas.Goals.Goal
  import Spectabas.AccountsFixtures

  setup do
    site =
      Spectabas.Repo.insert!(%Spectabas.Sites.Site{
        name: "Test Site",
        domain: "b.goals-test.com",
        public_key: "goals_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    %{site: site}
  end

  describe "create_goal/2" do
    test "creates a pageview goal", %{site: site} do
      assert {:ok, goal} =
               Goals.create_goal(site, %{
                 "name" => "Pricing page",
                 "goal_type" => "pageview",
                 "page_path" => "/pricing*"
               })

      assert goal.name == "Pricing page"
      assert goal.goal_type == "pageview"
      assert goal.page_path == "/pricing*"
      assert goal.site_id == site.id
    end

    test "creates a custom_event goal", %{site: site} do
      assert {:ok, goal} =
               Goals.create_goal(site, %{
                 "name" => "Signup complete",
                 "goal_type" => "custom_event",
                 "event_name" => "signup_complete"
               })

      assert goal.goal_type == "custom_event"
      assert goal.event_name == "signup_complete"
    end

    test "creates a click_element goal", %{site: site} do
      assert {:ok, goal} =
               Goals.create_goal(site, %{
                 "name" => "Click signup button",
                 "goal_type" => "click_element",
                 "element_selector" => "#signup-btn"
               })

      assert goal.goal_type == "click_element"
      assert goal.element_selector == "#signup-btn"
    end

    test "requires name", %{site: site} do
      assert {:error, changeset} =
               Goals.create_goal(site, %{
                 "goal_type" => "pageview",
                 "page_path" => "/test"
               })

      assert errors_on(changeset).name
    end

    test "requires page_path for pageview goals", %{site: site} do
      assert {:error, changeset} =
               Goals.create_goal(site, %{
                 "name" => "Test",
                 "goal_type" => "pageview"
               })

      assert errors_on(changeset).page_path
    end

    test "requires event_name for custom_event goals", %{site: site} do
      assert {:error, changeset} =
               Goals.create_goal(site, %{
                 "name" => "Test",
                 "goal_type" => "custom_event"
               })

      assert errors_on(changeset).event_name
    end

    test "requires element_selector for click_element goals", %{site: site} do
      assert {:error, changeset} =
               Goals.create_goal(site, %{
                 "name" => "Test",
                 "goal_type" => "click_element"
               })

      assert errors_on(changeset).element_selector
    end

    test "rejects invalid goal_type", %{site: site} do
      assert {:error, changeset} =
               Goals.create_goal(site, %{
                 "name" => "Test",
                 "goal_type" => "invalid"
               })

      assert errors_on(changeset).goal_type
    end
  end

  describe "delete_goal/2" do
    test "deletes a goal belonging to the site", %{site: site} do
      {:ok, goal} =
        Goals.create_goal(site, %{
          "name" => "Test",
          "goal_type" => "pageview",
          "page_path" => "/test"
        })

      assert {:ok, _} = Goals.delete_goal(site, goal.id)
      assert Goals.list_goals(site) == []
    end

    test "returns error for goal not belonging to site", %{site: site} do
      other_site =
        Spectabas.Repo.insert!(%Spectabas.Sites.Site{
          name: "Other",
          domain: "b.other.com",
          public_key: "other_key_#{System.unique_integer([:positive])}",
          active: true,
          gdpr_mode: "off",
          account_id: test_account().id
        })

      {:ok, goal} =
        Goals.create_goal(other_site, %{
          "name" => "Test",
          "goal_type" => "pageview",
          "page_path" => "/test"
        })

      assert {:error, :not_found} = Goals.delete_goal(site, goal.id)
    end
  end

  describe "check_goal/3" do
    test "matches pageview goal by exact path", %{site: site} do
      goal = %Goal{goal_type: "pageview", page_path: "/pricing"}
      assert Goals.check_goal(goal, site, %{url_path: "/pricing"})
      refute Goals.check_goal(goal, site, %{url_path: "/about"})
    end

    test "matches pageview goal with wildcard", %{site: site} do
      goal = %Goal{goal_type: "pageview", page_path: "/blog/*"}
      assert Goals.check_goal(goal, site, %{url_path: "/blog/hello-world"})
      assert Goals.check_goal(goal, site, %{url_path: "/blog/another-post"})
      refute Goals.check_goal(goal, site, %{url_path: "/about"})
    end

    test "matches custom_event goal", %{site: site} do
      goal = %Goal{goal_type: "custom_event", event_name: "signup"}
      assert Goals.check_goal(goal, site, %{event_name: "signup"})
      refute Goals.check_goal(goal, site, %{event_name: "login"})
    end

    test "matches click_element goal by ID selector", %{site: site} do
      goal = %Goal{goal_type: "click_element", element_selector: "#signup-btn"}

      assert Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_id" => "signup-btn", "_text" => "Sign Up"}
             })

      refute Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_id" => "other-btn", "_text" => "Other"}
             })
    end

    test "matches click_element goal by text selector", %{site: site} do
      goal = %Goal{goal_type: "click_element", element_selector: "text:Add to Cart"}

      assert Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_text" => "Add to Cart"}
             })

      refute Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_text" => "Remove from Cart"}
             })
    end

    test "matches click_element goal with text wildcard", %{site: site} do
      goal = %Goal{goal_type: "click_element", element_selector: "text:Add to*"}

      assert Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_text" => "Add to Cart"}
             })

      assert Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_text" => "Add to Wishlist"}
             })

      refute Goals.check_goal(goal, site, %{
               event_name: "_click",
               props: %{"_text" => "Remove"}
             })
    end

    test "click_element requires _click event_name", %{site: site} do
      goal = %Goal{goal_type: "click_element", element_selector: "#btn"}

      refute Goals.check_goal(goal, site, %{
               event_name: "other_event",
               props: %{"_id" => "btn"}
             })
    end

    test "returns false for unknown goal type", %{site: site} do
      refute Goals.check_goal(%Goal{goal_type: "unknown"}, site, %{})
    end
  end

  describe "list_goals/1" do
    test "returns goals sorted by name", %{site: site} do
      Goals.create_goal(site, %{"name" => "Zebra", "goal_type" => "pageview", "page_path" => "/z"})

      Goals.create_goal(site, %{"name" => "Alpha", "goal_type" => "pageview", "page_path" => "/a"})

      goals = Goals.list_goals(site)
      assert length(goals) == 2
      assert hd(goals).name == "Alpha"
    end
  end
end
