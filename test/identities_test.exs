defmodule Bonfire.Ghost.IdentitiesTest do
  @moduledoc """
  The persistent Ghost↔Bonfire identity link (one row per person: both Ghost IDs
  + account + author profile + last Ghost email) and the id-first provisioning
  funnel built on it. Pins the launch-critical guarantees:

  - changing a staff OR member email in Ghost updates the existing identity
    instead of forking a duplicate
  - changing the email on the Bonfire side neither breaks the link nor gets
    clobbered back by sync
  - attribution sticks to the linked author profile
  - stranded pre-link authors can be reconnected at sign-in (conservatively)
  """

  # `async: false` — provisions global Accounts and touches instance settings.
  use Bonfire.Ghost.DataCase, async: false
  use Repatch.ExUnit
  use Bonfire.Common.Settings
  use Bonfire.Common.E

  alias Bonfire.Data.Identity.Email
  alias Bonfire.Ghost.AdminAPI
  alias Bonfire.Ghost.Identities
  alias Bonfire.Ghost.Sync.Members
  alias Bonfire.Me.Accounts
  alias Bonfire.Me.Fake
  alias Bonfire.Me.Users

  # a Ghost staff payload — no "tiers" key, staff are not members
  defp staff(email, opts \\ []) do
    %{
      "id" => Keyword.fetch!(opts, :id),
      "email" => email,
      "name" => Keyword.get(opts, :name, "Ghost Staffer"),
      "slug" => Keyword.get(opts, :slug, "ghost-staffer"),
      "status" => "active"
    }
  end

  defp member(email, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, nil),
      "email" => email,
      "name" => Keyword.get(opts, :name, "Ghost Member"),
      "tiers" => Keyword.get(opts, :tiers, [])
    }
  end

  defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@test.local"

  defp set_local_email!(account, new_email) do
    account = Bonfire.Common.Repo.maybe_preload(account, :email)

    {:ok, _} =
      account.email
      |> Email.changeset(%{email_address: new_email}, must_confirm?: false)
      |> Bonfire.Common.Repo.update()

    Accounts.get_by_email(new_email)
  end

  describe "link/get" do
    test "roundtrip; staff and member IDs converge on ONE row per account" do
      account = Fake.fake_account!()

      assert {:ok, _} = Identities.link(account, staff_id: "s1", ghost_email: "a@x.test")
      assert {:ok, _} = Identities.link(account, member_id: "m1")

      row = Identities.get_by_staff_id("s1")
      assert row.account_id == account.id
      assert row.ghost_member_id == "m1"
      assert row.ghost_email == "a@x.test"
      assert Identities.get_by_member_id("m1").account_id == account.id

      # separate ID spaces: the same string under the other kind is nothing
      assert Identities.get_by_staff_id("m1") == nil
      assert Identities.get_by_member_id("s1") == nil
    end

    test "upsert never disconnects: a link without user/ids keeps what is already set" do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      assert {:ok, _} = Identities.link(account, staff_id: "s2", user: user)
      # account-only re-provisioning (e.g. backfill) passes no user
      assert {:ok, _} = Identities.link(account, staff_id: "s2", ghost_email: "b@x.test")

      row = Identities.get_by_staff_id("s2")
      assert row.user_id == user.id
      assert row.ghost_email == "b@x.test"
    end

    test "a Ghost ID already linked to a DIFFERENT account is refused" do
      a = Fake.fake_account!()
      b = Fake.fake_account!()

      assert {:ok, _} = Identities.link(a, staff_id: "s3")
      assert {:error, %Ecto.Changeset{}} = Identities.link(b, staff_id: "s3")
      assert Identities.get_by_staff_id("s3").account_id == a.id
    end

    test "staff_user/1 loads the linked profile; unknown ids are nil" do
      account = Fake.fake_account!()
      user = Fake.fake_user!(account)

      assert {:ok, _} = Identities.link(account, staff_id: "s4", user: user)
      assert Identities.staff_user("s4").id == user.id
      assert Identities.staff_user("nope") == nil
      assert Identities.get_by_account(account).ghost_staff_id == "s4"
    end
  end

  describe "provisioning writes the link" do
    test "staff account-only provisioning records staff id + ghost email" do
      email = unique_email("staffmap")
      assert {:ok, account} = Members.provision_from_ghost_staff(staff(email, id: "s10"))

      row = Identities.get_by_staff_id("s10")
      assert row.account_id == account.id
      assert row.ghost_email == email
      assert row.user_id == nil
    end

    test "the article-author path also records WHICH profile is the author" do
      assert {:ok, user} =
               Members.provision_from_ghost_staff(staff(unique_email("authormap"), id: "s11"),
                 create_user: true
               )

      assert Identities.get_by_staff_id("s11").user_id == user.id
    end

    test "a member payload records under the member column" do
      email = unique_email("membermap")
      assert {:ok, account} = Members.provision_from_ghost_member(member(email, id: "m10"))

      row = Identities.get_by_member_id("m10")
      assert row.account_id == account.id
      assert Identities.get_by_staff_id("m10") == nil
    end

    test "a person who is BOTH member and staff converges on one account and one row" do
      email = unique_email("both")

      assert {:ok, account} = Members.provision_from_ghost_member(member(email, id: "m11"))
      assert {:ok, account2} = Members.provision_from_ghost_staff(staff(email, id: "s12"))
      assert account2.id == account.id

      row = Identities.get_by_account(account)
      assert row.ghost_member_id == "m11"
      assert row.ghost_staff_id == "s12"
    end
  end

  describe "email changes follow the person, in both directions" do
    test "member email changed in Ghost (webhook/backfill payload): same account, email follows" do
      e1 = unique_email("m-before")
      e2 = unique_email("m-after")

      assert {:ok, account} = Members.provision_from_ghost_member(member(e1, id: "m20"))
      assert {:ok, account2} = Members.provision_from_ghost_member(member(e2, id: "m20"))

      assert account2.id == account.id
      assert Accounts.get_by_email(e2).id == account.id
      refute Accounts.get_by_email(e1)
    end

    test "an email changed on the BONFIRE side is kept: sync does not clobber it, the link survives" do
      ghost_email = unique_email("ghostside")
      personal = unique_email("personal")

      assert {:ok, author} =
               Members.provision_from_ghost_staff(staff(ghost_email, id: "s20"),
                 create_user: true
               )

      account = set_local_email!(Accounts.get_by_email(ghost_email), personal)

      # Ghost still reports the old address → local customization wins
      assert {:ok, again} =
               Members.provision_from_ghost_staff(staff(ghost_email, id: "s20"),
                 create_user: true
               )

      assert again.id == author.id
      assert Accounts.get_by_email(personal).id == account.id
      refute Accounts.get_by_email(ghost_email)

      # Ghost later changes its email too → STILL the local choice wins, but the
      # link keeps tracking Ghost's latest
      ghost_email2 = unique_email("ghostside2")

      assert {:ok, again2} =
               Members.provision_from_ghost_staff(staff(ghost_email2, id: "s20"),
                 create_user: true
               )

      assert again2.id == author.id
      assert Accounts.get_by_email(personal).id == account.id
      assert Identities.get_by_staff_id("s20").ghost_email == ghost_email2
    end

    test "a link recorded WITHOUT ghost_email never licenses overwriting the local email" do
      # the operator repair shape: a stranded pre-link account is re-keyed to the
      # author's real address and linked by id only (no ghost_email — the row is
      # created fresh, so nothing records what Ghost last had). The next sync must
      # not undo the repair by pushing Ghost's placeholder address back.
      real = unique_email("repaired")
      placeholder = unique_email("placeholder")

      account = Fake.fake_account!()
      user = Fake.fake_user!(account)
      account = set_local_email!(account, real)

      assert {:ok, _} = Identities.link(account, staff_id: "s61", user: user)

      assert {:ok, resolved} =
               Members.provision_from_ghost_staff(staff(placeholder, id: "s61"),
                 create_user: true
               )

      assert resolved.id == user.id
      assert Accounts.get_by_email(real).id == account.id
      refute Accounts.get_by_email(placeholder)
    end

    test "when the new Ghost email belongs to ANOTHER account, keep the old one (admin decision)" do
      other = Fake.fake_account!()
      other_email = other.email.email_address
      e1 = unique_email("conflict")

      assert {:ok, account} = Members.provision_from_ghost_staff(staff(e1, id: "s21"))
      assert {:ok, resolved} = Members.provision_from_ghost_staff(staff(other_email, id: "s21"))

      assert resolved.id == account.id
      assert Accounts.get_by_email(e1).id == account.id
      assert Accounts.get_by_email(other_email).id == other.id
    end
  end

  describe "attribution goes to the linked profile" do
    test "on an account with several profiles, the author path returns the LINKED one" do
      email = unique_email("multi")

      assert {:ok, first} =
               Members.provision_from_ghost_staff(staff(email, id: "s30"), create_user: true)

      account = Accounts.get_by_email(email)

      {:ok, second} =
        Users.create(
          %{profile: %{name: "Second Persona"}, character: %{username: "second_persona_zz"}},
          account
        )

      # the person designates their author profile (e.g. via repair/claim)
      assert {:ok, _} = Identities.link(account, staff_id: "s30", user: second)

      assert {:ok, resolved} =
               Members.provision_from_ghost_staff(staff(email, id: "s30"), create_user: true)

      assert resolved.id == second.id
      refute resolved.id == first.id
    end
  end

  describe "profile creation completes the link" do
    test "the after-signup hook records the freshly-created user via the stashed ghost id" do
      email = unique_email("hooked")
      assert {:ok, account} = Members.provision_from_ghost_staff(staff(email, id: "s40"))
      assert Identities.get_by_staff_id("s40").user_id == nil

      {:ok, user} =
        Users.create(
          %{profile: %{name: "Hooked Staffer"}, character: %{username: "hooked_staffer_zz"}},
          account
        )

      assert Identities.get_by_staff_id("s40").user_id == user.id
    end
  end

  describe "claim_split_author/1 (pre-link splits reconnected at sign-in)" do
    # a stranded STAFF identity: account-only provisioned from a staff payload
    # (stash marker with kind "staff", no identity row yet), profile created after
    defp stranded_staffer!(email, username) do
      {:ok, _} = Members.provision_from_ghost_staff(%{"email" => email, "name" => "Str A"})
      account = Accounts.get_by_email(email)

      {:ok, user} =
        Users.create(%{profile: %{name: "Str A"}, character: %{username: username}}, account)

      {account, user}
    end

    # the same, but stashed BEFORE the provisioning kind was recorded (pre-upgrade
    # accounts): claimable only once Ghost confirms the address is not a member's.
    # Built from a bare account so the stash is written fresh — Settings.put MERGES
    # into an existing value, so re-stashing a provisioned account would keep its kind.
    defp legacy_stranded!(email, username) do
      account = Fake.fake_account!() |> set_local_email!(email)

      {:ok, user} =
        Users.create(%{profile: %{name: "Legacy"}, character: %{username: username}}, account)

      Settings.put([:bonfire_ghost, :member], %{name: "Legacy"},
        scope: :account,
        current_account: account,
        skip_boundary_check: true
      )

      {account, user}
    end

    test "reconnects a stranded author: links ids, follows the email, returns their account" do
      old_email = unique_email("stranded")
      new_email = unique_email("stranded-new")
      {account, user} = stranded_staffer!(old_email, "strandedauthor")

      payload = staff(new_email, id: "s50", slug: "stranded-author")

      assert {:ok, claimed} = Members.claim_split_author(payload)
      assert claimed.id == account.id

      row = Identities.get_by_staff_id("s50")
      assert row.account_id == account.id
      assert row.user_id == user.id
      assert Accounts.get_by_email(new_email).id == account.id
      refute Accounts.get_by_email(old_email)
    end

    test "does NOT claim a non-Ghost-provisioned account with a matching username" do
      account = Fake.fake_account!()

      {:ok, _user} =
        Users.create(
          %{profile: %{name: "Regular"}, character: %{username: "regularperson"}},
          account
        )

      assert Members.claim_split_author(
               staff(unique_email("noclaim"), id: "s51", slug: "regular-person")
             ) == nil

      assert Identities.get_by_staff_id("s51") == nil
    end

    test "does NOT claim an account with several profiles" do
      email = unique_email("multi-noclaim")
      {account, _user} = stranded_staffer!(email, "multinoclaim")

      {:ok, _second} =
        Users.create(
          %{profile: %{name: "Another"}, character: %{username: "another_multi_zz"}},
          account
        )

      assert Members.claim_split_author(
               staff(unique_email("multi-new"), id: "s52", slug: "multi-noclaim")
             ) == nil
    end

    test "does NOT claim a Ghost MEMBER's account that merely shares the username" do
      # a subscriber who signed in via Ghost membership and picked a handle: their
      # account carries the same Ghost-provisioned marker as a stranded author, so
      # username alone must not hand it to a staffer (that would rewrite the
      # subscriber's login email and lock them out of their own account)
      subscriber_email = unique_email("subscriber")

      {:ok, _} =
        Members.provision_from_ghost_member(member(subscriber_email, id: "m60", name: "Maria"))

      account = Accounts.get_by_email(subscriber_email)

      {:ok, _} =
        Users.create(
          %{profile: %{name: "Maria"}, character: %{username: "mariacollide"}},
          account
        )

      staffer_email = unique_email("staffer")

      assert Members.claim_split_author(staff(staffer_email, id: "s60", slug: "maria-collide")) ==
               nil

      # the subscriber's account is untouched: same email, not linked to the staff id
      assert Accounts.get_by_email(subscriber_email).id == account.id
      refute Accounts.get_by_email(staffer_email)
      assert Identities.get_by_staff_id("s60") == nil
    end

    test "an account stashed before the kind was recorded IS claimable when Ghost knows no such member" do
      old_email = unique_email("legacy")
      new_email = unique_email("legacy-new")
      {account, user} = legacy_stranded!(old_email, "legacystaffer")

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
        {:ok, %{"members" => []}}
      end)

      assert {:ok, claimed} =
               Members.claim_split_author(
                 staff(new_email, id: "s62", slug: "legacy-staffer"),
                 client: :client
               )

      assert claimed.id == account.id
      assert Identities.get_by_staff_id("s62").user_id == user.id
    end

    test "an unlabelled account whose address IS a Ghost member's is refused" do
      old_email = unique_email("legacy-member")
      {account, _user} = legacy_stranded!(old_email, "legacymember")

      Repatch.patch(AdminAPI, :get_member_by_email, fn :client, _email, _opts ->
        {:ok, %{"members" => [member(old_email, id: "m62")]}}
      end)

      assert Members.claim_split_author(
               staff(unique_email("legacy-staff"), id: "s63", slug: "legacy-member"),
               client: :client
             ) == nil

      assert Accounts.get_by_email(old_email).id == account.id
      assert Identities.get_by_staff_id("s63") == nil
    end

    test "an unlabelled account is refused when no Ghost client is available (fails closed)" do
      old_email = unique_email("noclient")
      {_account, _user} = legacy_stranded!(old_email, "noclientstaffer")

      assert Members.claim_split_author(
               staff(unique_email("noclient-new"), id: "s64", slug: "noclient-staffer")
             ) == nil
    end

    test "is a no-op when the staff id is already linked (normal resolution applies)" do
      email = unique_email("linked")
      assert {:ok, account} = Members.provision_from_ghost_staff(staff(email, id: "s53"))

      assert Members.claim_split_author(staff(email, id: "s53")) == nil
      assert Identities.get_by_staff_id("s53").account_id == account.id
    end
  end
end
