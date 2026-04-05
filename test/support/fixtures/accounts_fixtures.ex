defmodule Spectabas.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Spectabas.Accounts` context.
  """

  import Ecto.Query

  alias Spectabas.Accounts
  alias Spectabas.Accounts.{Account, Scope}

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world1!"

  @doc "Get or create a shared test account for tests."
  def test_account do
    case Spectabas.Repo.get_by(Account, slug: "test-account") do
      %Account{} = acct ->
        acct

      nil ->
        Spectabas.Repo.insert!(%Account{
          name: "Test Account",
          slug: "test-account",
          site_limit: 100,
          active: true
        })
    end
  end

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    # Associate with test account
    account = test_account()

    {:ok, user} =
      user
      |> Accounts.User.profile_changeset(%{account_id: account.id})
      |> Spectabas.Repo.update()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  @doc "Create a site with the test account's account_id."
  def create_test_site(attrs) do
    account = test_account()
    attrs = Map.put_new(attrs, "account_id", account.id) |> Map.put_new(:account_id, account.id)
    Spectabas.Sites.create_site(attrs)
  end

  @doc "Insert a site struct directly with test account_id."
  def insert_test_site!(attrs) do
    account = test_account()

    %Spectabas.Sites.Site{}
    |> Map.merge(attrs)
    |> Map.put(:account_id, account.id)
    |> Map.put_new(:public_key, Spectabas.Sites.Site.generate_public_key())
    |> Spectabas.Repo.insert!()
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Spectabas.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Spectabas.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Spectabas.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
