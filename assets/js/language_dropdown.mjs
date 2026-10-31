const openLanguageMenus = (root) =>
	Array.from(root.querySelectorAll("details[data-language-switcher][open]"));

export const initLanguageDropdowns = (root) => {
	root.addEventListener(
		"click",
		(event) => {
			for (const menu of openLanguageMenus(root)) {
				if (!menu.contains(event.target)) menu.removeAttribute("open");
			}
		},
		true,
	);

	root.addEventListener(
		"keydown",
		(event) => {
			if (event.key !== "Escape") return;
			const menus = openLanguageMenus(root);
			if (menus.length === 0) return;

			const activeMenu = menus.find((menu) => menu.contains(root.activeElement));
			for (const menu of menus) menu.removeAttribute("open");
			(activeMenu || menus.at(-1)).querySelector("summary")?.focus();
			event.preventDefault();
			event.stopImmediatePropagation();
		},
		true,
	);
};
