# typed: strict
# frozen_string_literal: true

require "cmd/shared_examples/args_parse"
require "dev-cmd/update-sponsors"
require "utils/sponsors"

RSpec.describe Homebrew::DevCmd::UpdateSponsors do
  before do
    allow(Sponsors).to receive_messages(github_one_time: [], patreon: [], open_collective: [])
  end

  it_behaves_like "parseable arguments"

  test_each([
    { monthly_amount: 99, named_types: [], logo: false },
    { monthly_amount: 100, named_types: ["User"], logo: false },
    { monthly_amount: 249, named_types: ["User"], logo: false },
    { monthly_amount: 250, named_types: %w[User Organization], logo: false },
    { monthly_amount: 1000, named_types: %w[User Organization], logo: false },
    { monthly_amount: 1499, named_types: %w[User Organization], logo: false },
    { monthly_amount: 1500, named_types: %w[User Organization], logo: true },
    { monthly_amount: 1750, named_types: %w[User Organization], logo: true },
    {
      monthly_amount:   100,
      tier_description: "We will note your name in plain-text in our README.",
      named_types:      %w[User Organization],
      logo:             false,
    },
    {
      monthly_amount:   1000,
      tier_description: "We will put your name and linked organisation's logo in our README.",
      named_types:      %w[User Organization],
      logo:             true,
    },
    {
      monthly_amount:   50,
      tier_description: "We will note your user's name in our README (individuals only, no organisations).",
      named_types:      ["User"],
      logo:             false,
    },
  ].product(%w[User
               Organization], [0, 50], [:github, :open_collective])) do |sponsorship, type, price_increase, platform|
    it "uses current and subscribed tiers for #{type} at $#{sponsorship[:monthly_amount]} plus $#{price_increase}, " \
       "with tier #{sponsorship[:tier_description].inspect} on #{platform}" do
      readme = mktmpdir/"README.md"
      stub_const("HOMEBREW_REPOSITORY", readme.dirname)
      readme.write "Homebrew is generously supported by [Old sponsor](https://github.com/old).\n" \
                   "\n[![Old sponsor](https://github.com/old.png?size=64)](https://github.com/old)\n"
      command = described_class.new([])
      allow(command).to receive(:system_command).and_return(
        instance_double(SystemCommand::Result, status: instance_double(Process::Status, success?: false)),
      )
      allow(command).to receive(:puts)
      allow(GitHub).to receive(:sponsorship_tiers).with("Homebrew").and_return([
        { monthly_amount: 1, description: "You get a warm fuzzy feeling for supporting the project." },
        {
          monthly_amount: 100 + price_increase,
          description:    "We will note your user's name in plain-text in our README " \
                          "(individuals only, no organisations).",
        },
        {
          monthly_amount: 250 + price_increase,
          description:    "We will note your organisation's or user's name in plain-text in our README.",
        },
        {
          monthly_amount: 1500 + price_increase,
          description:    "We will put your name and linked organisation's logo in our README.",
        },
      ])
      allow(GitHub).to receive(:sponsorships).with("Homebrew").and_return([{
        type:,
        monthly_amount:   sponsorship[:monthly_amount] + price_increase,
        tier_description: sponsorship.fetch(:tier_description, ""),
        name:             "Sponsor",
        login:            "sponsor",
      }])
      if platform == :open_collective
        allow(GitHub).to receive(:sponsorships).with("Homebrew").and_return([{
          type: "User", monthly_amount: 1, tier_description: "", name: "Small sponsor", login: "small-sponsor"
        }])
        allow(Sponsors).to receive(:open_collective).and_return([{
          type:, monthly_amount: sponsorship[:monthly_amount] + price_increase,
          tier_descriptions: [sponsorship.fetch(:tier_description, "")], name: "Sponsor",
          url: "https://opencollective.com/sponsor", logo: "https://example.com/sponsor.png"
        }])
      end

      command.run

      expected = "Homebrew is generously supported by "
      expected += "Sponsor and " if sponsorship[:named_types].include?(type)
      expected += "many other users and organisations via [GitHub Sponsors](https://github.com/sponsors/Homebrew), " \
                  "[Patreon](https://www.patreon.com/homebrew) and [Open Collective](https://opencollective.com/homebrew).\n"
      expected += "\n<!-- release-sponsors -->\n"
      if sponsorship[:logo]
        expected += if platform == :github
          "[![Sponsor](https://github.com/sponsor.png?size=64)](https://github.com/sponsor)\n"
        else
          "[![Sponsor](https://example.com/sponsor.png)](https://opencollective.com/sponsor)\n"
        end
      end
      expected += "<!-- /release-sponsors -->\n"
      expect(readme.read).to eq(expected)
    end
  end

  describe "untrusted profile data" do
    # Keep each memoised helper with its type signature.
    # rubocop:disable RSpec/ScatteredLet
    sig { returns(Pathname) }
    let(:readme) { mktmpdir/"README.md" }

    sig { returns(Homebrew::DevCmd::UpdateSponsors) }
    let(:command) { described_class.new([]) }

    sig { returns(Sponsors::Record) }
    let(:sponsor) do
      {
        name: "Sponsor", type: "Organization", monthly_amount: 1000, tier_descriptions: [],
        logo: "https://example.com/logo.png", url: "https://example.com/sponsor"
      }
    end
    # rubocop:enable RSpec/ScatteredLet

    before do
      stub_const("HOMEBREW_REPOSITORY", readme.dirname)
      readme.write "Homebrew is generously supported by Old Sponsor.\n"
      allow(GitHub).to receive_messages(
        sponsorship_tiers: [{ monthly_amount: 1000, description: "Name and logo in our README" }],
        sponsorships:      [{
          name: "Small Sponsor", login: "small", type: "User", monthly_amount: 1, tier_description: ""
        }],
      )
      allow(Sponsors).to receive(:patreon).and_return([sponsor])
      allow(command).to receive(:system_command).and_return(
        instance_double(SystemCommand::Result, status: instance_double(Process::Status, success?: false)),
      )
      allow(command).to receive(:puts)
      allow(command).to receive(:opoo)
    end

    test_each([:patreon, :open_collective]) do |platform|
      it "escapes Markdown, HTML and newlines in #{platform} names" do
        sponsor[:name] = "A [link](https://example.com) \\ & *bold* <img>\r\nCafé’s 日本\tname\u0000"
        escaped_name = <<~'MARKDOWN'.chomp
          A \[link\]\(https\:\/\/example\.com\) \\ \& \*bold\* \<img\> Café’s 日本 name
        MARKDOWN
        allow(Sponsors).to receive(:patreon).and_return([])
        allow(Sponsors).to receive(platform).and_return([sponsor])

        command.run

        expect(readme.read).to include(
          "Homebrew is generously supported by #{escaped_name} and ",
          "[![#{escaped_name}](https://example.com/logo.png)](https://example.com/sponsor)",
        )
      end
    end

    test_each([
      "", "http://example.com", "javascript:alert(1)", "//example.com", "https:///sponsor",
      "https://[invalid", "https://example.com/a)b", "https://example.com/a(b",
      "https://example.com/<tag>", "https://example.com/a\\b", "https://example.com/a\nb",
      "https://example.com/a b"
    ].product([:logo, :url])) do |url, field|
      it "keeps name recognition without a logo for unsafe #{field} #{url.inspect}" do
        sponsor[field] = url

        command.run

        expect(readme.read).to include(
          "Homebrew is generously supported by Sponsor and ",
          "<!-- release-sponsors -->\n<!-- /release-sponsors -->",
        )
      end
    end
  end

  test_each([false, true]) do |failure|
    it "handles provider failure #{failure} without reporting an unchanged README as a failure" do
      readme = mktmpdir/"README.md"
      stub_const("HOMEBREW_REPOSITORY", readme.dirname)
      readme.write "Homebrew is generously supported by Existing Sponsor.\n"
      command = described_class.new([])
      allow(GitHub).to receive_messages(
        sponsorship_tiers: [{ monthly_amount: 100, description: "Name in our README" }],
        sponsorships:      [{
          name: "Existing Sponsor", login: "existing", type: "User", monthly_amount: 100, tier_description: ""
        }],
      )
      allow(command).to receive(:system_command).and_return(
        instance_double(SystemCommand::Result, status: instance_double(Process::Status, success?: true)),
      )
      if failure
        allow(Sponsors).to receive(:patreon).and_raise("Patreon unavailable")
        expect { command.run }.to raise_error("Patreon unavailable")
        expect(readme.read).to eq("Homebrew is generously supported by Existing Sponsor.\n")
      else
        expect { command.run }.to output("No changes to list of sponsors.\n").to_stdout
      end
    end
  end
end
