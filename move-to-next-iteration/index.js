import core from "@actions/core";
import GitHubProject from "github-project";

const run = async () => {
  try {
    const batchSize = Number(core.getInput("batch-size") || 20);
    const owner = core.getInput("owner");
    const number = Number(core.getInput("number"));
    const token = core.getInput("token");
    const iterationField = core.getInput("iteration-field"); // name of the iteration field
    const iterationType = core.getInput("iteration"); // last or current
    const newiterationType = core.getInput("new-iteration"); // current or next
    const statuses = core.getInput("statuses").split(",");
    const coreExclusedStatuses = core.getInput("excluded-statuses");
    const excludedStatuses = coreExclusedStatuses ? coreExclusedStatuses.split(",") : [];

    const ghProject = new GitHubProject({ owner, number, token, fields: { iteration: iterationField } });

    const items = await ghProject.items.list();
    core.debug(`items: ${JSON.stringify(items)}`);

    const project = await ghProject.getProperties();

    if (!project.fields) {
      core.setFailed(`No iteration field found with name ${iterationField}`);
      return;
    }
    core.debug(`project fields: ${JSON.stringify(project.fields)}`);

    const projectIterationField = project.fields.iteration;

    core.debug(`project iteration field: ${JSON.stringify(projectIterationField)}`);

    const lastIteration = projectIterationField.configuration.completedIterations[0];
    const currentIteration = projectIterationField.configuration.iterations[0];
    const nextIteration = projectIterationField.configuration.iterations[1];

    const iteration = iterationType === "last" ? lastIteration : currentIteration;

    let newIteration;
    if (newiterationType === "none") {
      newIteration = "";
    } else if (newiterationType === "current") {
      newIteration = currentIteration;
    } else {
      newIteration = nextIteration;
    }

    const filteredItems = items.filter((item) => {
      // If item is not in the old iteration, return false.
      if (item.fields.iteration && iteration?.title && item.fields.iteration !== iteration.title) {
        return false;
      }
      // If excludedStatuses are supplied, use that. Otherwise, use statuses.
      if (excludedStatuses?.length) {
        // Move item only if its status _is not_ in the excluded statuses list.
        return !excludedStatuses.includes(item.fields.status);
      } else {
        // Move item only if its status _is_ in the statuses list.
        return statuses.includes(item.fields.status);
      }
    });

    const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    for (let i = 0; i < filteredItems.length; i += batchSize) {
      const promises = filteredItems.slice(i, i + batchSize).map((item) => 
        ghProject.items.update(item.id, { iteration: newIteration ? newIteration.title : "" })
      );
      await Promise.all(promises);
      await delay(1000);
    }

    await delay(1000); // Get more time for next action
  } catch (error) {
    core.setFailed(error);
  }
};

run();
