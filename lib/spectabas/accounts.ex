defmodule Spectabas.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Spectabas.Repo

  alias Spectabas.Accounts.{
    Account,
    User,
    UserToken,
    UserNotifier,
    UserSitePermission,
    Invitation
  }

  alias Spectabas.{Audit, Sites}
  alias Spectabas.Sites.Site

  ## Authorization

  @doc """
  Checks if a user can access a given site.
  Platform admin can access all sites across all accounts.
  Superadmins and admins can access sites within their own account.
  Other roles need an explicit UserSitePermission record.
  """
  def can_access_site?(%User{role: :platform_admin}, _site), do: true

  def can_access_site?(%User{role: role, account_id: acct_id}, %{account_id: site_acct_id})
      when role in [:superadmin, :admin] do
    acct_id != nil and acct_id == site_acct_id
  end

  def can_access_site?(%User{id: user_id, account_id: acct_id}, %{
        id: site_id,
        account_id: site_acct_id
      }) do
    acct_id == site_acct_id and
      Repo.exists?(
        from(p in UserSitePermission,
          where: p.user_id == ^user_id and p.site_id == ^site_id
        )
      )
  end

  def can_access_site?(_, _), do: false

  @doc "Can the user perform write operations (create goals, campaigns, etc.)? Viewers cannot."
  def can_write?(%User{role: :viewer}), do: false
  def can_write?(%User{}), do: true
  def can_write?(_), do: false

  @doc "Can the user manage site settings and integrations? Viewers and analysts cannot."
  def can_manage_settings?(%User{role: r}) when r in [:viewer, :analyst], do: false
  def can_manage_settings?(%User{}), do: true
  def can_manage_settings?(_), do: false

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Get a single user by ID. Returns nil if not found.
  """
  def get_user(id), do: Repo.get(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user with email AND password (used by invitation acceptance).
  """
  def register_user_with_password(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Spectabas.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Spectabas.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user, metadata \\ %{}) do
    {token, user_token} = UserToken.build_session_token(user, metadata)
    Repo.insert!(user_token)
    token
  end

  @doc "List active sessions for a user."
  def list_user_sessions(%User{} = user) do
    cutoff = DateTime.add(DateTime.utc_now(), -14 * 86400, :second)

    Repo.all(
      from(t in UserToken,
        where: t.user_id == ^user.id and t.context == "session" and t.inserted_at > ^cutoff,
        order_by: [desc: t.last_active_at],
        select: %{
          id: t.id,
          ip: t.ip,
          user_agent: t.user_agent,
          last_active_at: t.last_active_at,
          inserted_at: t.inserted_at,
          token: t.token
        }
      )
    )
  end

  @doc "Delete all sessions for a user except the current one."
  def delete_other_user_sessions(%User{} = user, current_token) do
    {count, tokens} =
      Repo.delete_all(
        from(t in UserToken,
          where: t.user_id == ^user.id and t.context == "session" and t.token != ^current_token,
          select: t.token
        )
      )

    {count, tokens}
  end

  @doc "Delete all sessions for a user (admin force-logout)."
  def delete_all_user_sessions(%User{} = user) do
    {count, tokens} =
      Repo.delete_all(
        from(t in UserToken,
          where: t.user_id == ^user.id and t.context == "session",
          select: t.token
        )
      )

    {count, tokens}
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  # ─── Spectabas: Role & Permission Management ─────────────────────────

  @doc """
  Check if a user has a specific role on a site.
  """
  def has_site_role?(%User{role: :platform_admin}, _site, _role), do: true
  def has_site_role?(%User{role: :superadmin}, _site, _role), do: true

  def has_site_role?(%User{id: user_id}, %{id: site_id}, role) do
    Repo.exists?(
      from(p in UserSitePermission,
        where: p.user_id == ^user_id and p.site_id == ^site_id and p.role == ^role
      )
    )
  end

  @doc """
  Return all sites accessible to a user.
  Platform admin sees all sites. Superadmins/admins see their account's sites.
  Others get their explicitly permitted sites.
  """
  def accessible_sites(%User{role: :platform_admin}) do
    Sites.list_sites()
  end

  def accessible_sites(%User{role: role, account_id: acct_id})
      when role in [:superadmin, :admin] and not is_nil(acct_id) do
    Repo.all(from(s in Site, where: s.account_id == ^acct_id, order_by: [asc: s.name]))
  end

  def accessible_sites(%User{id: user_id}) do
    Repo.all(
      from(s in Site,
        join: p in UserSitePermission,
        on: p.site_id == s.id,
        where: p.user_id == ^user_id,
        order_by: [asc: s.name]
      )
    )
  end

  @doc """
  List users scoped to the caller's permissions.
  Platform admin sees all users. Others see only their account's users.
  """
  def list_users(%User{role: :platform_admin}) do
    Repo.all(from(u in User, order_by: [asc: u.email]))
  end

  def list_users(%User{account_id: acct_id}) when not is_nil(acct_id) do
    Repo.all(from(u in User, where: u.account_id == ^acct_id, order_by: [asc: u.email]))
  end

  def list_users(_), do: []

  @doc """
  Update a user's role. Only admins/superadmins should call this.
  """
  def update_user_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  def update_user_timezone(%User{} = user, timezone) do
    user
    |> User.profile_changeset(%{timezone: timezone})
    |> Repo.update()
  end

  def update_user_role(%User{} = admin, %User{} = user, new_role) do
    user
    |> User.profile_changeset(%{role: new_role})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Audit.log("user.role_changed", %{
          admin_id: admin.id,
          user_id: user.id,
          old_role: to_string(user.role),
          new_role: to_string(new_role)
        })

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Delete a user. Only admins/superadmins should call this.
  """
  def delete_user(%User{} = admin, %User{} = user) do
    case Repo.delete(user) do
      {:ok, deleted} ->
        Audit.log("user.deleted", %{
          admin_id: admin.id,
          deleted_user_id: user.id,
          deleted_email: user.email
        })

        {:ok, deleted}

      error ->
        error
    end
  end

  @doc "List all site permissions for a user."
  def list_user_permissions(%User{id: user_id}) do
    Repo.all(
      from(p in UserSitePermission,
        where: p.user_id == ^user_id,
        preload: [:site]
      )
    )
  end

  @doc "List all site permissions for a site."
  def list_site_permissions(%{id: site_id}) do
    Repo.all(
      from(p in UserSitePermission,
        where: p.site_id == ^site_id,
        preload: [:user]
      )
    )
  end

  @doc """
  Grant a user permission to a site with a specific role.
  """
  def grant_permission(%User{} = admin, %User{} = user, %{id: site_id}, role) do
    %UserSitePermission{}
    |> UserSitePermission.changeset(%{user_id: user.id, site_id: site_id, role: role})
    |> Repo.insert()
    |> case do
      {:ok, permission} ->
        Audit.log("permission.granted", %{
          admin_id: admin.id,
          user_id: user.id,
          site_id: site_id,
          role: to_string(role)
        })

        {:ok, permission}

      error ->
        error
    end
  end

  @doc """
  Revoke a user's permission to a site.
  """
  def revoke_permission(%User{} = admin, %User{} = user, %{id: site_id}) do
    case Repo.one(
           from(p in UserSitePermission,
             where: p.user_id == ^user.id and p.site_id == ^site_id
           )
         ) do
      nil ->
        {:error, :not_found}

      permission ->
        case Repo.delete(permission) do
          {:ok, _} ->
            Audit.log("permission.revoked", %{
              admin_id: admin.id,
              user_id: user.id,
              site_id: site_id
            })

            :ok

          error ->
            error
        end
    end
  end

  @doc """
  Create an invitation for a new user within an account.
  """
  def invite_user(%User{} = admin, email, role, account_id) do
    %Invitation{}
    |> Invitation.create_changeset(%{
      email: email,
      role: role,
      invited_by_id: admin.id,
      account_id: account_id
    })
    |> Repo.insert()
    |> case do
      {:ok, invitation} ->
        Audit.log("user.invited", %{
          admin_id: admin.id,
          invited_email: email,
          role: to_string(role)
        })

        Spectabas.Accounts.UserNotifier.deliver_invitation(%{
          email: email,
          token: invitation.token,
          role: to_string(role)
        })

        {:ok, invitation}

      error ->
        error
    end
  end

  @doc """
  List pending (not yet accepted) invitations, scoped to the caller's account.
  """
  def list_pending_invitations(%User{role: :platform_admin}) do
    Repo.all(
      from(i in Invitation,
        where: is_nil(i.accepted_at),
        order_by: [desc: i.inserted_at]
      )
    )
  end

  def list_pending_invitations(%User{account_id: acct_id}) when not is_nil(acct_id) do
    Repo.all(
      from(i in Invitation,
        where: is_nil(i.accepted_at) and i.account_id == ^acct_id,
        order_by: [desc: i.inserted_at]
      )
    )
  end

  def list_pending_invitations(_), do: []

  @doc """
  Look up a valid invitation by its plaintext token.
  Returns the invitation if found, not expired, and not yet accepted.
  """
  def get_valid_invitation(token) when is_binary(token) do
    token_hash = Invitation.hash_token(token)
    now = DateTime.utc_now()

    case Repo.one(from(i in Invitation, where: i.token_hash == ^token_hash)) do
      nil ->
        {:error, :not_found}

      %Invitation{accepted_at: accepted} when not is_nil(accepted) ->
        {:error, :already_accepted}

      %Invitation{expires_at: expires_at} = invitation ->
        if DateTime.compare(now, expires_at) == :lt do
          {:ok, invitation}
        else
          {:error, :expired}
        end
    end
  end

  @doc """
  Accept an invitation: register the user and mark the invitation as accepted.
  Accepts either an Invitation struct or a plaintext token string.
  """
  def accept_invitation(token, user_attrs) when is_binary(token) do
    case get_valid_invitation(token) do
      {:ok, invitation} -> accept_invitation(invitation, user_attrs)
      error -> error
    end
  end

  def accept_invitation(%Invitation{} = invitation, user_attrs) do
    # Verify email matches the invitation
    provided_email = to_string(user_attrs["email"] || user_attrs[:email] || "")

    if String.downcase(provided_email) != String.downcase(invitation.email) do
      {:error, :email_mismatch}
    else
      accept_invitation_inner(invitation, user_attrs)
    end
  end

  defp accept_invitation_inner(invitation, user_attrs) do
    Repo.transact(fn ->
      with {:ok, user} <- register_user_with_password(user_attrs) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        invitation
        |> Ecto.Changeset.change(accepted_at: now)
        |> Repo.update!()

        # Set the user's role and account to match the invitation
        {:ok, user} =
          user
          |> User.profile_changeset(%{role: invitation.role, account_id: invitation.account_id})
          |> Repo.update()

        Audit.log("invitation.accepted", %{
          user_id: user.id,
          invitation_id: invitation.id
        })

        {:ok, user}
      end
    end)
  end

  @doc """
  Resend an invitation by creating a new one with a fresh token and expiry.
  The old invitation is left as-is (for audit trail).
  """
  def resend_invitation(%User{} = admin, %Invitation{} = invitation) do
    # Delete all prior pending invitations for this email
    from(i in Invitation,
      where: i.email == ^invitation.email and is_nil(i.accepted_at)
    )
    |> Repo.delete_all()

    invite_user(admin, invitation.email, invitation.role, invitation.account_id)
  end

  @doc """
  Revoke/delete a pending invitation.
  """
  def delete_invitation(%Invitation{} = invitation) do
    Repo.delete(invitation)
  end

  # ─── Account Management ─────────────────────────────────────────────

  @doc "Create a new account. Only platform_admin should call this."
  def create_account(%User{role: :platform_admin} = admin, attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, account} ->
        Audit.log("account.created", %{
          admin_id: admin.id,
          account_id: account.id,
          name: account.name
        })

        {:ok, account}

      error ->
        error
    end
  end

  @doc "List all accounts."
  def list_accounts do
    Repo.all(from(a in Account, order_by: [asc: a.name]))
  end

  @doc "Get an account by ID. Raises if not found."
  def get_account!(id), do: Repo.get!(Account, id)

  @doc "Get an account by ID. Returns nil if not found."
  def get_account(id), do: Repo.get(Account, id)

  @doc "Update an account's attributes."
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  @doc "Count sites in an account."
  def account_site_count(account_id) do
    Repo.aggregate(from(s in Site, where: s.account_id == ^account_id), :count)
  end

  @doc "Check if an account can create another site (under its site_limit)."
  def can_create_site?(%User{role: :platform_admin}), do: true

  def can_create_site?(%User{account_id: nil}), do: false

  def can_create_site?(%User{account_id: acct_id}) do
    account = Repo.get!(Account, acct_id)
    current = Repo.aggregate(from(s in Site, where: s.account_id == ^acct_id), :count)
    current < account.site_limit
  end

  @doc "Get the account for a user, handling platform_admin (nil account_id)."
  def get_user_account(%User{account_id: nil}), do: nil
  def get_user_account(%User{account_id: acct_id}), do: Repo.get(Account, acct_id)
end
