defmodule Spectabas.Accounts.Webauthn do
  @moduledoc """
  WebAuthn/FIDO2 passkey support for 2FA.
  Uses the wax_ library for server-side verification.
  """

  import Ecto.Query
  alias Spectabas.Repo
  alias Spectabas.Accounts.WebauthnCredential

  @rp_name "Spectabas"

  @doc """
  Generate a registration challenge for a user.
  Returns {challenge, options_json} for the client.
  """
  def registration_challenge(user) do
    rp_id = rp_id()

    # Get existing credentials to exclude
    existing =
      Repo.all(
        from c in WebauthnCredential, where: c.user_id == ^user.id, select: c.credential_id
      )

    challenge =
      Wax.new_registration_challenge(
        rp_id: rp_id,
        rp_name: @rp_name,
        user_id: to_string(user.id),
        user_name: user.email,
        user_display_name: user.display_name || user.email,
        exclude_credentials: Enum.map(existing, &{&1, %{}}),
        attestation: "none"
      )

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp: %{id: rp_id, name: @rp_name},
      user: %{
        id: Base.url_encode64(to_string(user.id), padding: false),
        name: user.email,
        displayName: user.display_name || user.email
      },
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      authenticatorSelection: %{
        userVerification: "preferred",
        residentKey: "preferred"
      },
      timeout: 60_000,
      excludeCredentials:
        Enum.map(existing, fn cred_id ->
          %{type: "public-key", id: Base.url_encode64(cred_id, padding: false)}
        end)
    }

    {challenge, options}
  end

  @doc """
  Verify registration response and store the credential.
  """
  def register(
        user,
        challenge,
        attestation_object_b64,
        client_data_json_b64,
        name \\ "Security Key"
      ) do
    attestation_object = Base.url_decode64!(attestation_object_b64, padding: false)
    client_data_json = Base.url_decode64!(client_data_json_b64, padding: false)

    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, {auth_data, _attestation_result}} ->
        %WebauthnCredential{}
        |> WebauthnCredential.changeset(%{
          user_id: user.id,
          credential_id: auth_data.attested_credential_data.credential_id,
          public_key:
            :erlang.term_to_binary(auth_data.attested_credential_data.credential_public_key),
          sign_count: auth_data.sign_count,
          name: name
        })
        |> Repo.insert()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate an authentication challenge.
  Returns {challenge, options_json} for the client.
  """
  def authentication_challenge(user) do
    credentials = Repo.all(from c in WebauthnCredential, where: c.user_id == ^user.id)

    if credentials == [] do
      {:error, :no_credentials}
    else
      challenge =
        Wax.new_authentication_challenge(
          rp_id: rp_id(),
          allow_credentials: Enum.map(credentials, &{&1.credential_id, %{}}),
          user_verification: "preferred"
        )

      options = %{
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        rpId: rp_id(),
        allowCredentials:
          Enum.map(credentials, fn cred ->
            %{type: "public-key", id: Base.url_encode64(cred.credential_id, padding: false)}
          end),
        timeout: 60_000,
        userVerification: "preferred"
      }

      {challenge, options}
    end
  end

  @doc """
  Verify an authentication response.
  """
  def authenticate(
        user,
        challenge,
        credential_id_b64,
        authenticator_data_b64,
        client_data_json_b64,
        signature_b64
      ) do
    credential_id = Base.url_decode64!(credential_id_b64, padding: false)
    authenticator_data = Base.url_decode64!(authenticator_data_b64, padding: false)
    client_data_json = Base.url_decode64!(client_data_json_b64, padding: false)
    signature = Base.url_decode64!(signature_b64, padding: false)

    cred =
      Repo.one(
        from c in WebauthnCredential,
          where: c.user_id == ^user.id and c.credential_id == ^credential_id
      )

    if cred do
      public_key = :erlang.binary_to_term(cred.public_key, [:safe])

      case Wax.authenticate(
             credential_id,
             authenticator_data,
             signature,
             client_data_json,
             challenge,
             [{credential_id, public_key, cred.sign_count}]
           ) do
        {:ok, auth_data} ->
          # Update sign count
          cred
          |> Ecto.Changeset.change(sign_count: auth_data.sign_count)
          |> Repo.update()

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :credential_not_found}
    end
  end

  @doc """
  List all credentials for a user.
  """
  def list_credentials(user) do
    Repo.all(
      from c in WebauthnCredential, where: c.user_id == ^user.id, order_by: [desc: c.inserted_at]
    )
  end

  @doc """
  Delete a credential.
  """
  def delete_credential(user, credential_id) do
    case Repo.one(
           from c in WebauthnCredential,
             where: c.id == ^credential_id and c.user_id == ^user.id
         ) do
      nil -> {:error, :not_found}
      cred -> Repo.delete(cred)
    end
  end

  @doc """
  Check if a user has any WebAuthn credentials.
  """
  def has_credentials?(user) do
    Repo.exists?(from c in WebauthnCredential, where: c.user_id == ^user.id)
  end

  defp rp_id do
    Application.get_env(:spectabas, :root_host, "localhost")
    |> to_string()
    |> String.replace("www.", "")
  end
end
