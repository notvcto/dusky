#!/usr/bin/env python3
import re
import sys
from pathlib import Path

# Semantic mapping: Bridges the gap between what an element *is* and the correct CSS/Matugen logic.
# The hex codes are pulled directly from your current firefox_websites.css for accurate live previews.
ROLES = {
    "1": {"name": "Main Background", "prop": "background-color", "var": "var(--surface)", "hex": "#101418"},
    "2": {"name": "Panel/Card Background", "prop": "background-color", "var": "var(--surface_container)", "hex": "#1c2024"},
    "3": {"name": "Primary Text (Headings/Body)", "prop": "color", "var": "var(--on_surface)", "hex": "#e0e2e8"},
    "4": {"name": "Muted Text (Subtitles/Dates)", "prop": "color", "var": "var(--on_surface_variant)", "hex": "#c2c7cf"},
    "5": {"name": "Borders & Dividers", "prop": "border-color", "var": "var(--outline)", "hex": "#8c9198"},
    "6": {"name": "Accent Element (Buttons/Links)", "prop": "background-color", "var": "var(--primary)", "hex": "#9bcbfb"},
    "7": {"name": "Text on Accent Button", "prop": "color", "var": "var(--on_primary)", "hex": "#003353"},
    "8": {"name": "Error/Warning Alert", "prop": "background-color", "var": "var(--error)", "hex": "#ffb4ab"}
}

def print_menu() -> None:
    print("\n--- Select Element Role ---")
    for key, data in ROLES.items():
        print(f"[{key}] {data['name']}")
    print("---------------------------")

def generate_css(domain: str, rules: list[dict[str, str]], mode: str = "production") -> str:
    """Generates the final Mozilla domain-scoped CSS string."""
    # The domain is strictly sanitized upstream, so quotes are already mathematically impossible here.
    css_parts = [f'@-moz-document domain("{domain}") {{\n\n']
    
    for rule in rules:
        role_data = ROLES[rule['role']]
        css_value = role_data['var'] if mode == "production" else role_data['hex']
        
        css_parts.append(f"    /* {role_data['name']} */\n")
        css_parts.append(f"    {rule['selector']} {{\n")
        css_parts.append(f"        {role_data['prop']}: {css_value} !important;\n")
        css_parts.append("    }\n\n")
        
    css_parts.append("}\n")
    return "".join(css_parts)

def main() -> None:
    print("\n=== Dusky Dynamic Theme Builder ===")
    raw_domain = input("Enter the website domain (e.g., google.com): ").strip()
    
    # [FIX] Replaced A-Z strict regex with \w to safely support Internationalized Domain Names (IDNs)
    # while continuing to prevent Path Traversal or CSS injection (forbids slashes, quotes, spaces).
    domain = re.sub(r'[^\w.-]', '', raw_domain)
    
    if not domain:
        print("Valid domain is required. Exiting.")
        return

    collected_rules: list[dict[str, str]] = []
    
    # Input Loop
    while True:
        print("\n" + "="*40)
        selector = input("Paste the CSS selector (or press Enter to finish):\n> ").strip()
        
        if not selector:
            break
            
        print_menu()
        role_choice = input("Select the role (1-8): ").strip()
        
        # [FIX] Replaced computationally heavier pattern matching with standard O(1) dictionary lookup
        if role_choice in ROLES:
            collected_rules.append({
                "selector": selector,
                "role": role_choice
            })
            print(f"[+] Added rule for {ROLES[role_choice]['name']}")
        else:
            print("[!] Invalid choice. Rule skipped.")

    if not collected_rules:
        print("\nNo rules collected. Exiting.")
        return

    # Generate Templates
    production_css = generate_css(domain, collected_rules, mode="production")
    preview_css = generate_css(domain, collected_rules, mode="preview")

    print("\n\n" + "="*50)
    print("🎨 HOT PREVIEW TEMPLATE (For Stylus)")
    print("Copy this into Stylus to see your changes immediately:")
    print("="*50)
    print(preview_css)
    print("="*50)

    # Ask to save Production Template
    print("\nYour Managing/Production Template uses dynamic var(--...) variables.")
    save_prompt = input(f"Do you want to automatically save the Production template to ~/.cache/dusky_themer/{domain}.css? (Y/n): ").strip().lower()

    match save_prompt:
        case 'n' | 'no':
            print("\nHere is your Production Code to copy manually:\n")
            print(production_css)
        case _:
            # Resolve the path securely relying purely on Pathlib
            cache_dir = Path.home() / ".cache" / "dusky_themer"
            cache_dir.mkdir(parents=True, exist_ok=True)
            
            # The domain variable is now guaranteed to be safe from traversal characters
            file_path = cache_dir / f"{domain}.css"
            
            try:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(production_css)
                print(f"\n[✓] Success! Production template saved to: {file_path}")
                print("You can now open your Dusky TUI Manager to enable and deploy it.")
            except OSError as e:  # [FIX] Use specific OSError instead of catching blind exceptions
                print(f"\n[!] Error saving file: {e}")
                print("Here is your Production Code instead:\n")
                print(production_css)

if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):  # [FIX] Added EOFError to prevent crash on Ctrl+D/Piped streams
        print("\n\nExiting Theme Builder. Goodbye!")
        sys.exit(0)
