export const adminEscapeTarget = ({ key, hasOpenPopover, hasOpenDialog }) => {
	if (key !== "Escape") return "none";
	if (hasOpenPopover) return "popover";
	if (hasOpenDialog) return "dialog";

	return "none";
};

export const shouldDismissOpenPopoverFromPointer = ({
	hasOpenPopover,
	targetInsidePopover,
	targetInsideInvoker,
}) => hasOpenPopover && !targetInsidePopover && !targetInsideInvoker;
