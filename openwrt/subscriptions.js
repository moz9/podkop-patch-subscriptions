"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.podkop.main as main";

function createSubscriptionsContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    main.SubscriptionsTab.initController();
    return main.SubscriptionsTab.render();
  };
}

const EntryPoint = {
  createSubscriptionsContent,
};

return baseclass.extend(EntryPoint);
